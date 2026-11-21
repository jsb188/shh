#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
sources=()
for source in Sources/*.swift; do
    if [[ "$source" != Sources/main.swift ]]; then sources+=("$source"); fi
done
xcrun swiftc -target "$(uname -m)-apple-macos14.2" -module-cache-path build/ModuleCache \
    "${sources[@]}" Tests/*.swift -o build/test-playback
build/test-playback
