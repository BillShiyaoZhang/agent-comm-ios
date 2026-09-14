#!/bin/bash
# Exercise the real app store with deterministic transport and in-memory journal doubles.
# No credentials, network, simulator, or Keychain access is used.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
check_root="$(mktemp -d "${TMPDIR:-/tmp}/workspace-store-check.XXXXXX")"
trap 'rm -rf "$check_root"' EXIT
swiftc -emit-library -emit-module -module-name AgentWorkspaceKit -swift-version 5 \
  -module-cache-path "$check_root/module-cache" \
  "$repo_root"/Packages/AgentWorkspaceKit/Sources/AgentWorkspaceKit/*.swift \
  -emit-module-path "$check_root/AgentWorkspaceKit.swiftmodule" \
  -o "$check_root/libAgentWorkspaceKit.dylib"
swiftc -parse-as-library -swift-version 5 -module-cache-path "$check_root/module-cache" \
  -I "$check_root" -L "$check_root" -lAgentWorkspaceKit \
  -Xlinker -rpath -Xlinker "$check_root" \
  "$repo_root/agent comm ios/WorkspaceStore.swift" \
  "$repo_root/Tests/WorkspaceStoreHarness.swift" \
  -o "$check_root/workspace-store-check"
"$check_root/workspace-store-check"
