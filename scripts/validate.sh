#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$HOME/.dotnet:$PATH"

echo "==> Swift tests"
(cd "$ROOT/macos" && swift build && swift test)

if command -v dotnet >/dev/null 2>&1 || [[ -x "$HOME/.dotnet/dotnet" ]]; then
  echo "==> Windows build"
  DOTNET="$HOME/.dotnet/dotnet"
  if command -v dotnet >/dev/null 2>&1; then DOTNET="$(command -v dotnet)"; fi
  "$DOTNET" build "$ROOT/windows/StickyWin/StickyWin.csproj"
else
  echo "==> Windows build skipped: dotnet is unavailable" >&2
fi

echo "==> MCP checks"
(cd "$ROOT/mcp" && npm ci --no-audit --no-fund && npm run typecheck)

echo "==> QA tooling"
python3 -m py_compile "$ROOT/tools/e2e/sticky_e2e.py"
python3 "$ROOT/tools/e2e/sticky_e2e.py" doctor
