#!/usr/bin/env python3
"""Measure raw key-byte forwarding through ourocode_tty using a Linux PTY.

This is a diagnostic harness, not a real-terminal reproduction. It drives the
built ``ourocode_tty`` helper over a local Linux PTY and measures how many of
the bytes written to the terminal input actually reach the Elixir-side protocol
stream (fd4), comparing the received bytes to the sent payload.

Important limitation (reported in every result): a local PTY applies end-to-end
backpressure. ``ourocode_tty`` uses a blocking ``write_all`` on fd4, so once the
fd4 pipe fills, the input-forwarding thread stalls and the PTY writer blocks
instead of dropping. Zero loss here therefore means "the backpressured local
transport preserved bytes", NOT "the real terminal cannot lose input". Real
user-visible loss requires a no-backpressure source (a real keyboard/terminal,
tmux, SSH) overflowing the raw tty input buffer while the reader stalls during a
slow redraw. Use this harness to (a) prove the forwarding layer does not corrupt
or reorder bytes and (b) measure partial receipt under a bounded deadline; the
Elixir read-loop behaviour tests cover the actual fix properties.
"""

import argparse
import json
import os
import pty
import select
import subprocess
import sys
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "rust/ourocode_ipc/target/release/ourocode_tty"

TRANSPORT_MODEL = "local_linux_pty + blocking fd4 write_all backpressure"


def parse_args():
    parser = argparse.ArgumentParser(
        description="Measure key-byte forwarding through ourocode_tty over a local PTY."
    )
    parser.add_argument("--bytes", type=int, default=200_000, dest="byte_count")
    parser.add_argument("--consumer-delay-ms", type=float, default=20.0)
    parser.add_argument(
        "--scenario",
        choices=("all", "slow_consumer", "fast_consumer"),
        default="all",
    )
    parser.add_argument(
        "--idle-timeout-ms",
        type=float,
        default=2000.0,
        help="Finalize the sample after this idle gap once the writer has finished.",
    )
    parser.add_argument(
        "--total-timeout-ms",
        type=float,
        default=120_000.0,
        help="Hard safety deadline: finalize (partial) instead of hanging.",
    )
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="Fault-injection check: prove the harness reports partial receipt "
        "(complete=false, dropped>0) under a deliberately tiny deadline instead "
        "of hanging. Exits non-zero if the contract is violated.",
    )
    args = parser.parse_args()
    if args.byte_count <= 0:
        parser.error("--bytes must be positive")
    if args.consumer_delay_ms < 0:
        parser.error("--consumer-delay-ms must be non-negative")
    if args.idle_timeout_ms <= 0:
        parser.error("--idle-timeout-ms must be positive")
    if args.total_timeout_ms <= 0:
        parser.error("--total-timeout-ms must be positive")
    return args


def require_helper():
    if HELPER.is_file() and os.access(HELPER, os.X_OK):
        return
    print(
        f"ourocode_tty is missing: {HELPER}\n"
        "Build it with: (cd rust/ourocode_ipc && cargo build --release)",
        file=sys.stderr,
    )
    raise SystemExit(2)


def spawn_helper():
    """Spawn ourocode_tty with fd0/1=PTY slave and fd3/fd4=protocol pipes.

    All descriptors allocated here are owned by a single try/except so that a
    failure at any allocation or spawn step closes everything already opened.
    """
    opened = []

    def track(*fds):
        opened.extend(fds)
        return fds if len(fds) > 1 else fds[0]

    child = None
    try:
        master, slave = track(*pty.openpty())
        pin_r, pin_w = track(*os.pipe())
        pout_r, pout_w = track(*os.pipe())

        def wire_fds():
            os.dup2(pin_r, 3)
            os.dup2(pout_w, 4)
            for fd in (master, slave, pin_r, pin_w, pout_r, pout_w):
                if fd not in (0, 1, 2, 3, 4):
                    os.close(fd)

        child = subprocess.Popen(
            [str(HELPER)],
            stdin=slave,
            stdout=slave,
            stderr=subprocess.PIPE,
            close_fds=False,
            preexec_fn=wire_fds,
            start_new_session=True,
        )
    except BaseException as error:
        # Close everything we opened; the child (if any) is torn down too.
        if child is not None and child.poll() is None:
            child.kill()
            child.wait()
        for fd in opened:
            _close(fd)
        if isinstance(error, (OSError, ValueError)):
            print(f"cannot start ourocode_tty: {error}", file=sys.stderr)
            raise SystemExit(2)
        raise

    # Parent keeps master (writes keystrokes), pin_w (frames), pout_r (reads keys).
    _close(slave)
    _close(pin_r)
    _close(pout_w)
    return child, master, pin_w, pout_r


def _close(fd):
    try:
        os.close(fd)
    except OSError:
        pass


def read_header(fd, child):
    deadline = time.monotonic() + 3
    buffered = b""
    while time.monotonic() < deadline:
        ready, _, _ = select.select([fd], [], [], deadline - time.monotonic())
        if ready:
            buffered += os.read(fd, 4096)
            if b"\n" in buffered:
                header, remainder = buffered.split(b"\n", 1)
                try:
                    columns, rows = header.split()
                    int(columns)
                    int(rows)
                except ValueError as error:
                    raise RuntimeError(f"invalid ourocode_tty header: {header!r}") from error
                return remainder
        if child.poll() is not None:
            stderr = child.stderr.read().decode(errors="replace")
            raise RuntimeError(f"ourocode_tty exited before its header (stderr: {stderr!r})")
    raise RuntimeError("timed out waiting for ourocode_tty size header")


def write_all(fd, payload, failure):
    try:
        view = memoryview(payload)
        while view:
            written = os.write(fd, view)
            view = view[written:]
    except BaseException as error:  # deliver the writer failure to the main thread
        failure.append(error)


def _compare(received, payload):
    """Compare received byte stream to the sent payload without hiding faults."""
    common = min(len(received), len(payload))
    first_mismatch = -1
    for i in range(common):
        if received[i] != payload[i]:
            first_mismatch = i
            break
    content_mismatch = first_mismatch != -1
    missing = max(0, len(payload) - len(received))
    extra = max(0, len(received) - len(payload))
    complete = (len(received) == len(payload)) and not content_mismatch
    return {
        "sent": len(payload),
        "received": len(received),
        "dropped": missing,
        "extra": extra,
        "content_mismatch": content_mismatch,
        "first_mismatch_offset": first_mismatch,
        "complete": complete,
    }


def measure(scenario, payload, delay_seconds, idle_timeout, total_timeout):
    child, master, pin_w, pout_r = spawn_helper()
    received = bytearray()
    try:
        received.extend(read_header(pout_r, child))
        os.set_blocking(pout_r, False)
        failure = []
        writer = threading.Thread(target=write_all, args=(master, payload, failure), daemon=True)
        started = time.monotonic()
        writer.start()

        # Do not consume while the initial burst arrives, so a slow-consumer run
        # forces fd4 backpressure the way a redraw loop that cannot keep up would.
        if scenario == "slow_consumer" and delay_seconds:
            time.sleep(delay_seconds)

        last_progress = time.monotonic()
        hard_deadline = started + total_timeout
        while True:
            now = time.monotonic()
            # Success: writer done and everything forwarded.
            if not writer.is_alive() and len(received) >= len(payload):
                break
            # Hard safety deadline: finalize a partial sample instead of hanging.
            if now >= hard_deadline:
                break
            # Idle deadline: writer finished but no new bytes for idle_timeout.
            if not writer.is_alive() and (now - last_progress) >= idle_timeout:
                break

            ready, _, _ = select.select([pout_r], [], [], min(0.1, idle_timeout))
            if ready:
                try:
                    chunk = os.read(pout_r, 65536)
                except BlockingIOError:
                    chunk = b""
                if chunk:
                    received.extend(chunk)
                    last_progress = time.monotonic()

            if failure:
                raise RuntimeError(f"PTY writer failed: {failure[0]}")
            if child.poll() is not None and len(received) < len(payload):
                # Child exited early: one final non-blocking drain, then finalize.
                try:
                    tail = os.read(pout_r, 1 << 20)
                    if tail:
                        received.extend(tail)
                except (BlockingIOError, OSError):
                    pass
                stderr = child.stderr.read().decode(errors="replace")
                if len(received) < len(payload):
                    # Not a harness error: report the measured partial receipt.
                    if stderr:
                        print(f"note: ourocode_tty exited early (stderr: {stderr!r})", file=sys.stderr)
                    break

            if scenario == "slow_consumer" and delay_seconds:
                time.sleep(delay_seconds)

        writer.join(timeout=1)
        elapsed = time.monotonic() - started
        stats = _compare(bytes(received), payload)
        result = {
            "scenario": scenario,
            **stats,
            "dropped_pct": round(stats["dropped"] * 100 / len(payload), 4) if payload else 0.0,
            "elapsed_s": round(elapsed, 3),
            "idle_timeout_s": idle_timeout,
            "total_timeout_s": total_timeout,
            "transport_model": TRANSPORT_MODEL,
            "local_pty_only": True,
            "does_not_reproduce_real_terminal_loss": True,
        }
        print(
            f"{scenario}: sent={result['sent']} received={result['received']} "
            f"dropped={result['dropped']} extra={result['extra']} "
            f"content_mismatch={result['content_mismatch']} complete={result['complete']} "
            f"({result['dropped_pct']}%) elapsed={result['elapsed_s']}s"
        )
        print(json.dumps(result, separators=(",", ":")))
        print(
            "note: local Linux PTY + blocking fd4 backpressure; not a real-terminal "
            "loss reproduction.",
            file=sys.stderr,
        )
        return result
    finally:
        for fd in (pin_w, pout_r, master):
            _close(fd)
        if child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=2)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
        if child.stderr is not None:
            child.stderr.close()


def build_payload(byte_count):
    unit = b"abcdefghijklmnopqrstuvwxyz0123456789"
    return (unit * ((byte_count + len(unit) - 1) // len(unit)))[:byte_count]


def run_self_test():
    """Prove the measurement contract: under a deliberately tiny deadline with a
    large slow-consumer payload, the harness must finalize a PARTIAL sample
    (complete=false and dropped>0) rather than hanging on the exit condition."""
    require_helper()
    payload = build_payload(2_000_000)
    print("self-test: forcing partial receipt with a tiny total deadline...", file=sys.stderr)
    result = measure(
        "slow_consumer",
        payload,
        delay_seconds=0.25,  # large per-drain delay so the sample cannot complete
        idle_timeout=0.2,
        total_timeout=1.0,  # hard 1s deadline forces a partial, bounded finalize
    )
    ok = (
        result["complete"] is False
        and result["dropped"] > 0
        and result["received"] < result["sent"]
    )
    if ok:
        print(
            "self-test PASSED: harness reported a bounded partial sample "
            f"(dropped={result['dropped']}, complete=False) without hanging."
        )
        return 0
    print(
        "self-test FAILED: harness did not report partial loss under a tiny deadline "
        f"(result={json.dumps(result, separators=(',', ':'))}).",
        file=sys.stderr,
    )
    return 1


def main():
    args = parse_args()
    if args.self_test:
        return run_self_test()

    require_helper()
    payload = build_payload(args.byte_count)
    scenarios = (
        ("slow_consumer", "fast_consumer")
        if args.scenario == "all"
        else (args.scenario,)
    )
    idle_timeout = args.idle_timeout_ms / 1000
    total_timeout = args.total_timeout_ms / 1000
    try:
        for scenario in scenarios:
            measure(
                scenario,
                payload,
                args.consumer_delay_ms / 1000 if scenario == "slow_consumer" else 0,
                idle_timeout,
                total_timeout,
            )
    except RuntimeError as error:
        print(f"measurement failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
