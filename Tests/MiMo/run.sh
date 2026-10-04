#!/bin/bash
set -eu
cd "$(dirname "$0")/../.."
test_dir=$(mktemp -d /tmp/mimo-reader.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT
python3 Tests/MiMo/fixtures.py "$test_dir"
swiftc boringNotch/models/ActivityArbiter.swift BoringNotchXPCHelper/ChromiumLocalStorageReader.swift BoringNotchXPCHelper/MiMoTasksReader.swift Tests/MiMo/main.swift -o "$test_dir/test"
"$test_dir/test" "$test_dir"
