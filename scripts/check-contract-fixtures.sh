#!/bin/bash
# Compare checked-in Swift fixtures with the language-neutral contract source.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
deploy_root="${1:-$repo_root/../agent-collaboration-deploy}"
source_root="$deploy_root/agent-collaboration-web/packages/client-contract/fixtures"
target_root="$repo_root/Packages/AgentWorkspaceKit/Tests/AgentWorkspaceKitTests/Fixtures"
if [ ! -d "$source_root" ]; then
  echo "Missing deploy contract fixtures: $source_root" >&2
  exit 1
fi
for source in "$source_root"/*.json; do
  name="$(basename "$source")"
  cmp "$source" "$target_root/$name"
  echo "MATCH $name"
done
for target in "$target_root"/*.json; do
  test -f "$source_root/$(basename "$target")"
done
python3 - "$source_root/../index.d.ts" "$repo_root/Packages/AgentWorkspaceKit/Sources/AgentWorkspaceKit/WorkspaceModels.swift" <<'PY'
import pathlib
import re
import sys

contract = pathlib.Path(sys.argv[1]).read_text()
swift = pathlib.Path(sys.argv[2]).read_text().split("public struct PendingCall", 1)[0]
methods = re.search(r'RPC_METHODS: readonly \[(.*?)\]', contract).group(1)
expected = set(re.findall(r'"([a-z._]+)"', methods))
actual = set(re.findall(r'case \w+ = "([a-z._]+)"', swift))
actual.add("capabilities")
if expected != actual:
    raise SystemExit(f"RPC method mismatch: missing={sorted(expected - actual)} extra={sorted(actual - expected)}")
print(f"MATCH {len(expected)} RPC methods")
PY
