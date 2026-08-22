#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../macos"
swift build "$@"
echo "Sticky binary: $(swift build --show-bin-path)/Sticky"
