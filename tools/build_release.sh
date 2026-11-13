#!/bin/bash
# Build an optimized local release and install it in /Applications.
set -euo pipefail
release_script_dir="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$release_script_dir/build_release.py" "$@"
