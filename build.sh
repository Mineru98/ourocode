#!/usr/bin/env bash
# Builds the native tty helper and the ourocode escript.
set -euo pipefail
cd "$(dirname "$0")"

echo "==> building native tty helper (rust)"
cargo build --release --manifest-path rust/ourocode_ipc/Cargo.toml --bin ourocode_tty
mkdir -p bin
cp rust/ourocode_ipc/target/release/ourocode_tty bin/ourocode_tty

echo "==> building escript"
mix escript.build

echo "==> done. run: ./ourocode"
