//! ourocode terminal driver helper.
//!
//! The Elixir runtime stays the single source of truth; this is the seed's
//! replaceable native frontend piece. An escript cannot raw-mode its own
//! terminal (no `tcsetattr` in Elixir; `stty` via :os.cmd has no ctty), and
//! a Port-spawned child has no controlling terminal so `/dev/tty` is not an
//! option either.
//!
//! So we use the terminal fds the BEAM already holds. Erlang's
//! `:nouse_stdio` port option leaves fds 0/1/2 inherited from the BEAM (the
//! real terminal) and moves the Erlang<->port protocol to fds 3 and 4.
//! termios works on any tty fd whether or not it is the ctty, so we set raw
//! mode directly on fd 0.
//!
//!   * fd 0  terminal input   (keystrokes; raw termios set here)
//!   * fd 1  terminal output  (frames written verbatim)
//!   * fd 3  protocol in      (frames from Elixir)
//!   * fd 4  protocol out     (size header then key byte stream to Elixir)
//!
//! Protocol: first thing written to fd 4 is "<cols> <rows>\n"; everything
//! after is the raw key stream. Restores the original termios on exit.

use std::sync::Once;
use std::{mem, process, ptr, thread};

const TTY_IN: libc::c_int = 0;
const TTY_OUT: libc::c_int = 1;
const PROTO_IN: libc::c_int = 3;
const PROTO_OUT: libc::c_int = 4;

static mut SAVED: Option<libc::termios> = None;
static RESTORE_ONCE: Once = Once::new();

const RESTORE_SEQUENCE: &[u8] = b"\x1b[?2004l\x1b[?1003l\x1b[?1006l\x1b[?25h\x1b[?1049l";

fn exit_after_restore(status: libc::c_int) -> ! {
    RESTORE_ONCE.call_once(|| unsafe { restore() });
    process::exit(status)
}

unsafe fn restore() {
    if let Some(saved) = SAVED {
        libc::tcsetattr(TTY_IN, libc::TCSANOW, &saved);
    }
    libc::write(
        TTY_OUT,
        RESTORE_SEQUENCE.as_ptr() as *const libc::c_void,
        RESTORE_SEQUENCE.len(),
    );
}

const EXIT_SIGNALS: [libc::c_int; 5] = [
    libc::SIGTERM,
    libc::SIGINT,
    libc::SIGHUP,
    libc::SIGPIPE,
    libc::SIGQUIT,
];

fn block_exit_signals() -> Option<libc::sigset_t> {
    unsafe {
        let mut set: libc::sigset_t = mem::zeroed();
        libc::sigemptyset(&mut set);
        for signal in EXIT_SIGNALS {
            libc::sigaddset(&mut set, signal);
        }

        (libc::pthread_sigmask(libc::SIG_BLOCK, &set, ptr::null_mut()) == 0).then_some(set)
    }
}

fn wait_for_exit_signal(set: libc::sigset_t) {
    let mut signal = 0;
    if unsafe { libc::sigwait(&set, &mut signal) } != 0 {
        exit_after_restore(1);
    }
    exit_after_restore(128 + signal);
}

fn write_all(fd: libc::c_int, buf: &[u8]) -> bool {
    let mut off = 0usize;
    while off < buf.len() {
        let w = unsafe {
            libc::write(
                fd,
                buf.as_ptr().add(off) as *const libc::c_void,
                buf.len() - off,
            )
        };
        if w <= 0 {
            return false;
        }
        off += w as usize;
    }
    true
}

fn main() {
    // fd 0 must be a terminal. If not (piped / no tty), bail so Elixir falls
    // back to the plain renderer.
    if unsafe { libc::isatty(TTY_IN) } != 1 {
        process::exit(1);
    }

    let term = unsafe {
        let mut term: libc::termios = mem::zeroed();
        if libc::tcgetattr(TTY_IN, &mut term) != 0 {
            process::exit(1);
        }
        SAVED = Some(term);
        term
    };

    let signal_set = block_exit_signals().unwrap_or_else(|| process::exit(1));

    unsafe {
        let mut raw = term;
        libc::cfmakeraw(&mut raw);
        if libc::tcsetattr(TTY_IN, libc::TCSANOW, &raw) != 0 {
            process::exit(1);
        }
    }

    if thread::Builder::new()
        .name("ourocode-tty-signals".into())
        .spawn(move || wait_for_exit_signal(signal_set))
        .is_err()
    {
        exit_after_restore(1);
    }

    let (cols, rows) = unsafe {
        let mut ws: libc::winsize = mem::zeroed();
        if libc::ioctl(TTY_OUT, libc::TIOCGWINSZ, &mut ws) == 0 && ws.ws_col > 0 && ws.ws_row > 0 {
            (ws.ws_col, ws.ws_row)
        } else {
            (120u16, 40u16)
        }
    };
    if !write_all(PROTO_OUT, format!("{} {}\n", cols, rows).as_bytes()) {
        exit_after_restore(1);
    }

    // terminal input -> Elixir
    if thread::Builder::new()
        .name("ourocode-tty-input".into())
        .spawn(move || {
            let mut buf = [0u8; 4096];
            loop {
                let n =
                    unsafe { libc::read(TTY_IN, buf.as_mut_ptr() as *mut libc::c_void, buf.len()) };
                if n <= 0 {
                    exit_after_restore(0);
                }
                if !write_all(PROTO_OUT, &buf[..n as usize]) {
                    exit_after_restore(0);
                }
            }
        })
        .is_err()
    {
        exit_after_restore(1);
    }

    // Elixir frames -> terminal. EOF means Elixir is done.
    let mut buf = [0u8; 16384];
    loop {
        let n = unsafe { libc::read(PROTO_IN, buf.as_mut_ptr() as *mut libc::c_void, buf.len()) };
        if n <= 0 || !write_all(TTY_OUT, &buf[..n as usize]) {
            break;
        }
    }

    exit_after_restore(0);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn restore_sequence_has_complete_ordered_terminal_cleanup() {
        assert_eq!(
            RESTORE_SEQUENCE,
            b"\x1b[?2004l\x1b[?1003l\x1b[?1006l\x1b[?25h\x1b[?1049l"
        );
    }
}
