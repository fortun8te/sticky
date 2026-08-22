#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../mcp"
npm ci --no-audit --no-fund
npm run typecheck
npm run build
