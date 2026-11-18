#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build
sources=()
for source in Sources/DevDock/*.swift; do
  if [[ "$source" != */App.swift ]]; then
    sources+=("$source")
  fi
done
xcrun swiftc -target "$(uname -m)-apple-macosx13.0" -swift-version 5 -parse-as-library "${sources[@]}" \
  Tests/DevDockTests/DevDockTests.swift -o .build/devdock-checks
.build/devdock-checks
