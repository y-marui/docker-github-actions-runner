#!/usr/bin/env bash
set -euo pipefail

test "$(id -u)" -ne 0
test -s /var/lib/dpkg/status
test -s /etc/ld.so.cache
python3 - <<'PYTHON'
import ctypes
from pathlib import Path

empty = [str(path) for path in Path("/usr/lib").rglob("*.so*")
         if path.is_file() and path.stat().st_size == 0]
if empty:
    raise SystemExit(f"Empty shared libraries: {empty}")

for library in ("libEGL.so.1", "libxkbcommon.so.0", "libgbm.so.1", "libnss3.so"):
    ctypes.CDLL(library)
PYTHON
swiftlint version
lint_dir=$(mktemp -d)
trap 'rm -rf "$lint_dir"' EXIT
printf 'let answer = 42\n' > "$lint_dir/Example.swift"
(cd "$lint_dir" && swiftlint lint --no-cache --quiet)
printf 'let x=1\n' > "$lint_dir/Example.swift"
if (cd "$lint_dir" && swiftlint lint --no-cache --strict --quiet); then
    echo "SwiftLint unexpectedly accepted invalid formatting" >&2
    exit 1
fi
echo "Image smoke checks passed"
