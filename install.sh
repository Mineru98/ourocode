#!/usr/bin/env bash
# ourocode installer — builds the native tty helper + escript, then detects
# the model backends already available on this machine (Codex OAuth, and any
# claude/codex/gemini CLI you are already using). Mirrors the Ouroboros
# installer: probe the environment, then let you pick with /model.
set -euo pipefail
cd "$(dirname "$0")"

echo "==> ourocode install"

if ! command -v mix >/dev/null 2>&1; then
  echo "error: elixir/mix not found. install elixir first." >&2
  exit 1
fi
if ! command -v cargo >/dev/null 2>&1; then
  echo "error: cargo (rust) not found. install rust first." >&2
  exit 1
fi

echo "==> building native tty helper"
cargo build --release --manifest-path rust/ourocode_ipc/Cargo.toml --bin ourocode_tty
mkdir -p bin
cp rust/ourocode_ipc/target/release/ourocode_tty bin/ourocode_tty

echo "==> building escript"
mix deps.get >/dev/null 2>&1 || true
mix escript.build

# ourocode surfaces the whole Ouroboros capability graph, so install Ouroboros
# the canonical, full way (same official installer the docs use). Best-effort
# and non-fatal: ourocode still builds/runs without it, and at runtime
# McpDaemon falls back to `uvx --from ouroboros-ai[mcp,claude]` regardless.
# Skip with OUROCODE_SKIP_OUROBOROS=1; override source via OUROBOROS_INSTALL_URL.
OUROBOROS_INSTALL_URL="${OUROBOROS_INSTALL_URL:-https://raw.githubusercontent.com/Q00/ouroboros/main/scripts/install.sh}"
if [ "${OUROCODE_SKIP_OUROBOROS:-0}" = "1" ]; then
  echo "==> skipping Ouroboros install (OUROCODE_SKIP_OUROBOROS=1)"
elif command -v curl >/dev/null 2>&1; then
  echo "==> installing Ouroboros (full, official installer)"
  if curl -fsSL "$OUROBOROS_INSTALL_URL" | bash; then
    echo "    Ouroboros installed."
  else
    echo "    warning: Ouroboros install did not complete — ooo workflows will" >&2
    echo "    fall back to uvx at runtime, or rerun the official installer:" >&2
    echo "      curl -fsSL $OUROBOROS_INSTALL_URL | bash" >&2
  fi
else
  echo "==> skipping Ouroboros install (curl not found)" >&2
  echo "    install it later: see https://github.com/Q00/ouroboros" >&2
fi

# The official installer's headless variant detection can land on a lean
# package WITHOUT the [mcp] extra — but ourocode's whole point is the MCP
# capability graph, so the mcp extra must never be missing. Guarantee it
# explicitly (idempotent upgrade), mirroring the interview skill's own
# uv > pipx > pip upgrade path. Best-effort: McpDaemon's runtime
# `uvx --from ouroboros-ai[mcp,claude]` is the final backstop.
if [ "${OUROCODE_SKIP_OUROBOROS:-0}" != "1" ]; then
  echo "==> ensuring Ouroboros MCP extra (ouroboros-ai[mcp,claude])"
  if command -v uv >/dev/null 2>&1; then
    uv tool install --upgrade --python ">=3.12" ouroboros-ai \
      --with "mcp>=1.26.0,<2.0.0" \
      --with "claude-agent-sdk>=0.1.0" \
      --with "anthropic>=0.52.0" \
      && echo "    MCP extra ensured via uv." \
      || echo "    warning: uv mcp-ensure failed (uvx runtime fallback still works)" >&2
  elif command -v pipx >/dev/null 2>&1; then
    pipx install --force "ouroboros-ai[mcp,claude]" \
      && echo "    MCP extra ensured via pipx." \
      || echo "    warning: pipx mcp-ensure failed (uvx runtime fallback still works)" >&2
  elif command -v python3 >/dev/null 2>&1; then
    python3 -m pip install --user --upgrade "ouroboros-ai[mcp,claude]" \
      && echo "    MCP extra ensured via pip." \
      || echo "    warning: pip mcp-ensure failed (uvx runtime fallback still works)" >&2
  else
    echo "    note: no uv/pipx/python3 — MCP arrives at runtime via uvx fallback" >&2
  fi
fi

echo ""
./ourocode --detect

echo ""
echo "==> ready"
echo "  run:        ./ourocode"
echo "  pick model: type  /model   (or /login for ChatGPT/Codex)"
echo "  CLI backends need no login — your existing terminal session is reused."
