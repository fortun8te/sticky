#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../mcp"
[ -d node_modules ] || npm install --no-audit --no-fund >&2
npm run build >&2
TOKEN_FILE="$HOME/Library/Application Support/Sticky/control-token"
if [ ! -r "$TOKEN_FILE" ]; then
  echo "Sticky's local bridge is not ready. Open Sticky once, then try again." >&2
  exit 1
fi
export STICKY_CONTROL_TOKEN="$(tr -d '[:space:]' < "$TOKEN_FILE")"
exec node dist/server.js
