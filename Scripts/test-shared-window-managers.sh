#!/bin/bash
# Compile the actual portable policy and WindowCommand.ID, without AppKit or running a tiler.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
{
    printf 'import Foundation\nstruct WindowCommand {\n'
    awk '/^    enum ID:/ { active=1 } active {print} active && /^    }$/ {exit}' \
        Tinycast/Features/WindowManagement/Model/WindowCommand.swift
    printf '}\n'
    awk '/^enum SharedWindowManagerSelection:/ {active=1} /^\/\/\/ Small, allowlisted CLI adapter\./ {exit} active {print}' \
        Tinycast/Features/WindowManagement/UI/WindowCommandCoordinator.swift
} > "$tmp/Policy.swift"
swiftc -swift-version 6 "$tmp/Policy.swift" Tests/shared-window-manager-test.swift -o "$tmp/test"
"$tmp/test"
