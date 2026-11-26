#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
E=Tinycast/Features/Extensions
swiftc -swift-version 6 "$E/Model/ExtensionManifest.swift" \
    "$E/Model/ExtensionRefreshPolicy.swift" "$E/Model/ExtensionRefreshState.swift" \
    "$E/Service/ExtensionCatalog.swift" \
    Tinycast/Platform/AppDisplayName.swift Tests/ext-install-transaction-test.swift -o "$tmp/test"
"$tmp/test"
