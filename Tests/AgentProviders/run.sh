#!/bin/bash
set -eu
cd "$(dirname "$0")/../.."
test_dir=$(mktemp -d /tmp/agent-providers.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT
for suite in AgentProviders ActivityArbiter CodexUnread WorkBuddy AgentTimeline; do
    swiftc boringNotch/models/ActivityArbiter.swift "Tests/$suite/main.swift" -o "$test_dir/$suite"
    "$test_dir/$suite"
done
swiftc -parse-as-library boringNotch/models/ActivityArbiter.swift boringNotch/services/AgentTaskProvider.swift Tests/AgentProviders/routing.swift -o "$test_dir/routing"
"$test_dir/routing"
sed '/^import Defaults$/d' boringNotch/services/CodexPinnedTasksService.swift > "$test_dir/CodexPinnedTasksService.swift"
swiftc -parse-as-library boringNotch/models/ActivityArbiter.swift boringNotch/services/AgentTaskProvider.swift "$test_dir/CodexPinnedTasksService.swift" Tests/AgentProviders/service.swift -o "$test_dir/service"
"$test_dir/service"
