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

#[cfg(unix)]
mod unix {
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::{mem, process, ptr, thread};

    const TTY_IN: libc::c_int = 0;
    const TTY_OUT: libc::c_int = 1;
    const PROTO_IN: libc::c_int = 3;
    const PROTO_OUT: libc::c_int = 4;

    static mut SAVED: Option<libc::termios> = None;
    static RESTORED: AtomicBool = AtomicBool::new(false);

    unsafe fn restore() {
        if RESTORED.swap(true, Ordering::SeqCst) {
            return;
        }
        if let Some(saved) = SAVED {
            libc::tcsetattr(TTY_IN, libc::TCSANOW, &saved);
        }
        let seq = b"\x1b[?25h\x1b[?1049l";
        libc::write(TTY_OUT, seq.as_ptr() as *const libc::c_void, seq.len());
    }

    extern "C" fn on_signal(_sig: libc::c_int) {
        unsafe { restore() };
        process::exit(0);
    }

    fn install_signal(sig: libc::c_int) {
        unsafe {
            let mut sa: libc::sigaction = mem::zeroed();
            sa.sa_sigaction = on_signal as *const () as usize;
            libc::sigemptyset(&mut sa.sa_mask);
            libc::sigaction(sig, &sa, ptr::null_mut());
        }
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

    pub fn run() {
        // fd 0 must be a terminal. If not (piped / no tty), bail so Elixir falls
        // back to the plain renderer.
        if unsafe { libc::isatty(TTY_IN) } != 1 {
            process::exit(1);
        }

        unsafe {
            let mut term: libc::termios = mem::zeroed();
            if libc::tcgetattr(TTY_IN, &mut term) != 0 {
                process::exit(1);
            }
            SAVED = Some(term);

            let mut raw = term;
            libc::cfmakeraw(&mut raw);
            libc::tcsetattr(TTY_IN, libc::TCSANOW, &raw);
        }

        for sig in [libc::SIGTERM, libc::SIGINT, libc::SIGHUP, libc::SIGPIPE] {
            install_signal(sig);
        }

        let (cols, rows) = unsafe {
            let mut ws: libc::winsize = mem::zeroed();
            if libc::ioctl(TTY_OUT, libc::TIOCGWINSZ, &mut ws) == 0
                && ws.ws_col > 0
                && ws.ws_row > 0
            {
                (ws.ws_col, ws.ws_row)
            } else {
                (120u16, 40u16)
            }
        };
        write_all(PROTO_OUT, format!("{} {}\n", cols, rows).as_bytes());

        // terminal input -> Elixir
        thread::spawn(move || {
            let mut buf = [0u8; 4096];
            loop {
                let n =
                    unsafe { libc::read(TTY_IN, buf.as_mut_ptr() as *mut libc::c_void, buf.len()) };
                if n <= 0 || !write_all(PROTO_OUT, &buf[..n as usize]) {
                    process::exit(0);
                }
            }
        });

        // Elixir frames -> terminal. EOF means Elixir is done.
        let mut buf = [0u8; 16384];
        loop {
            let n =
                unsafe { libc::read(PROTO_IN, buf.as_mut_ptr() as *mut libc::c_void, buf.len()) };
            if n <= 0 || !write_all(TTY_OUT, &buf[..n as usize]) {
                break;
            }
        }

        unsafe { restore() };
        process::exit(0);
    }
}

#[cfg(unix)]
fn main() {
    unix::run();
}

#[cfg(windows)]
fn main() {
    windows::run();
}

#[cfg(not(any(unix, windows)))]
fn main() {
    eprintln!("ourocode_tty: unsupported platform; falling back");
    std::process::exit(1);
}

#[cfg(windows)]
mod windows {
    use std::ffi::c_void;
    use std::process;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::thread;

    use windows_sys::Win32::Foundation::{HANDLE, INVALID_HANDLE_VALUE};
    use windows_sys::Win32::Storage::FileSystem::{ReadFile, WriteFile};
    use windows_sys::Win32::System::Console::{
        GetConsoleMode, GetConsoleScreenBufferInfo, GetStdHandle, SetConsoleMode,
        CONSOLE_SCREEN_BUFFER_INFO, ENABLE_ECHO_INPUT, ENABLE_LINE_INPUT, ENABLE_PROCESSED_INPUT,
        ENABLE_VIRTUAL_TERMINAL_INPUT, ENABLE_VIRTUAL_TERMINAL_PROCESSING, STD_INPUT_HANDLE,
        STD_OUTPUT_HANDLE,
    };

    const PROTO_IN: libc::c_int = 3;
    const PROTO_OUT: libc::c_int = 4;

    static RESTORED: AtomicBool = AtomicBool::new(false);
    static mut INPUT_HANDLE: HANDLE = std::ptr::null_mut();
    static mut OUTPUT_HANDLE: HANDLE = std::ptr::null_mut();
    static mut INPUT_MODE: u32 = 0;
    static mut OUTPUT_MODE: u32 = 0;

    struct ConsoleGuard;

    impl Drop for ConsoleGuard {
        fn drop(&mut self) {
            restore();
        }
    }

    fn restore() {
        if RESTORED.swap(true, Ordering::SeqCst) {
            return;
        }

        unsafe {
            if !INPUT_HANDLE.is_null() && INPUT_HANDLE != INVALID_HANDLE_VALUE {
                SetConsoleMode(INPUT_HANDLE, INPUT_MODE);
            }
            if !OUTPUT_HANDLE.is_null() && OUTPUT_HANDLE != INVALID_HANDLE_VALUE {
                SetConsoleMode(OUTPUT_HANDLE, OUTPUT_MODE);
            }
        }

        let _ = write_console(b"\x1b[?25h\x1b[?1049l");
    }

    fn write_proto(buf: &[u8]) -> bool {
        let mut off = 0usize;
        while off < buf.len() {
            let remaining = buf.len() - off;
            let chunk = remaining.min(i32::MAX as usize);
            let written = unsafe {
                libc::write(
                    PROTO_OUT,
                    buf.as_ptr().add(off) as *const c_void,
                    chunk as libc::c_uint,
                )
            };
            if written <= 0 {
                return false;
            }
            off += written as usize;
        }
        true
    }

    fn read_proto(buf: &mut [u8]) -> isize {
        (unsafe {
            libc::read(
                PROTO_IN,
                buf.as_mut_ptr() as *mut c_void,
                buf.len() as libc::c_uint,
            )
        }) as isize
    }

    fn write_console(buf: &[u8]) -> bool {
        let handle = unsafe { OUTPUT_HANDLE };
        if handle.is_null() || handle == INVALID_HANDLE_VALUE {
            return false;
        }

        let mut off = 0usize;
        while off < buf.len() {
            let chunk = (buf.len() - off).min(u32::MAX as usize);
            let mut written = 0u32;
            let ok = unsafe {
                WriteFile(
                    handle,
                    buf.as_ptr().add(off),
                    chunk as u32,
                    &mut written,
                    std::ptr::null_mut(),
                )
            };
            if ok == 0 || written == 0 {
                return false;
            }
            off += written as usize;
        }
        true
    }

    fn read_console(buf: &mut [u8]) -> isize {
        let handle = unsafe { INPUT_HANDLE };
        if handle.is_null() || handle == INVALID_HANDLE_VALUE {
            return -1;
        }

        let mut read = 0u32;
        let ok = unsafe {
            ReadFile(
                handle,
                buf.as_mut_ptr(),
                buf.len().min(u32::MAX as usize) as u32,
                &mut read,
                std::ptr::null_mut(),
            )
        };
        if ok == 0 {
            -1
        } else {
            read as isize
        }
    }

    fn terminal_size() -> (i16, i16) {
        unsafe {
            let mut info: CONSOLE_SCREEN_BUFFER_INFO = std::mem::zeroed();
            if GetConsoleScreenBufferInfo(OUTPUT_HANDLE, &mut info) != 0 {
                let cols = info.srWindow.Right - info.srWindow.Left + 1;
                let rows = info.srWindow.Bottom - info.srWindow.Top + 1;
                if cols > 0 && rows > 0 {
                    return (cols, rows);
                }
            }
        }

        (120, 40)
    }

    fn setup_console() -> Option<ConsoleGuard> {
        unsafe {
            INPUT_HANDLE = GetStdHandle(STD_INPUT_HANDLE);
            OUTPUT_HANDLE = GetStdHandle(STD_OUTPUT_HANDLE);
            if INPUT_HANDLE.is_null()
                || INPUT_HANDLE == INVALID_HANDLE_VALUE
                || OUTPUT_HANDLE.is_null()
                || OUTPUT_HANDLE == INVALID_HANDLE_VALUE
            {
                return None;
            }

            let mut input_mode = 0u32;
            let mut output_mode = 0u32;
            if GetConsoleMode(INPUT_HANDLE, &mut input_mode) == 0 {
                return None;
            }
            if GetConsoleMode(OUTPUT_HANDLE, &mut output_mode) == 0 {
                return None;
            }

            INPUT_MODE = input_mode;
            OUTPUT_MODE = output_mode;

            let raw_input = (input_mode
                & !(ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT | ENABLE_PROCESSED_INPUT))
                | ENABLE_VIRTUAL_TERMINAL_INPUT;
            let vt_output = output_mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING;

            if SetConsoleMode(INPUT_HANDLE, raw_input) == 0 {
                return None;
            }
            if SetConsoleMode(OUTPUT_HANDLE, vt_output) == 0 {
                SetConsoleMode(INPUT_HANDLE, INPUT_MODE);
                return None;
            }
        }

        Some(ConsoleGuard)
    }

    pub fn run() {
        let _guard = match setup_console() {
            Some(guard) => guard,
            None => process::exit(1),
        };

        let (cols, rows) = terminal_size();
        if !write_proto(format!("{} {}\n", cols, rows).as_bytes()) {
            process::exit(1);
        }

        thread::spawn(move || {
            let mut buf = [0u8; 4096];
            loop {
                let n = read_console(&mut buf);
                if n <= 0 || !write_proto(&buf[..n as usize]) {
                    process::exit(0);
                }
            }
        });

        let mut buf = [0u8; 16384];
        loop {
            let n = read_proto(&mut buf);
            if n <= 0 || !write_console(&buf[..n as usize]) {
                break;
            }
        }

        process::exit(0);
    }
}
