#!/bin/bash
set -eu
cd "$(dirname "$0")/../.."
node --test Tests/MiMoBridge/*.test.mjs
test_dir=$(mktemp -d /tmp/mimo-bridge.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT
swiftc BoringNotchXPCHelper/ChromiumLocalStorageReader.swift BoringNotchXPCHelper/MiMoTasksReader.swift BoringNotchXPCHelper/MiMoBridgeClient.swift Tests/MiMoBridge/installer/main.swift -o "$test_dir/installer"
"$test_dir/installer"
