#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build
xcrun swiftc -swift-version 5 -parse-as-library \
  Sources/DevDock/Models.swift Sources/DevDock/Runtime.swift Sources/DevDock/Store.swift \
  Tests/DevDockTests/DevDockTests.swift -o .build/devdock-checks
.build/devdock-checks
