#!/bin/sh
# Removes intra-SDK module imports so the pod compiles as the single module
# CocoaPods builds. The SDK is four SwiftPM modules that import each other;
# the podspec globs their sources into one pod target, where `import
# AdvenueCore` names a module that does not exist. Same strip the React
# Native and Flutter vendor scripts apply on the way into their one-module
# trees — see SWIFT_MODULES in vendor-natives.mjs. Fails loud on leftovers:
# a silently unstripped pod installs, links, and then does not compile in
# the integrator's project.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
PATTERN='^[[:space:]]*import[[:space:]]+(Advenue|AdvenueCore|AdvenuePlatform|AdvenueFirebase)[[:space:]]*$'

find "$HERE/Sources" -name '*.swift' -exec sed -i '' -E "/$PATTERN/d" {} +

leftovers=$(grep -rn -E "$PATTERN" "$HERE/Sources" --include='*.swift' || true)
if [ -n "$leftovers" ]; then
  echo "strip-module-imports: intra-SDK imports remain:" >&2
  echo "$leftovers" >&2
  exit 1
fi
echo "strip-module-imports: ok"
