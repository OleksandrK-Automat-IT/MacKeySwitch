#!/bin/bash
# Runs the test suite.
#
# When the active developer directory is a full Xcode, plain `swift test` works and this
# script just forwards to it. When it is the Command Line Tools, swift-testing lives in a
# framework that is not on the default search paths: the test target, the SwiftPM-generated
# runner, and the runtime loader each need to be pointed at it.
#
# Worth knowing: without these flags SwiftPM does not fail. It silently builds a runner
# containing no tests and exits 0, so a misconfigured setup looks like a green run. That is
# also why the flags live here rather than in Package.swift — per-target settings never
# reach the generated runner.
set -euo pipefail
cd "$(dirname "$0")"

ACTIVE_DEVELOPER_DIR="$(xcode-select -p 2>/dev/null || echo '')"

ARGS=()
for candidate in "$ACTIVE_DEVELOPER_DIR" /Library/Developer/CommandLineTools; do
    [ -n "$candidate" ] || continue
    frameworks="$candidate/Library/Developer/Frameworks"
    if [ -d "$frameworks/Testing.framework" ]; then
        ARGS=(-Xswiftc -F -Xswiftc "$frameworks"
              -Xlinker -rpath -Xlinker "$frameworks"
              -Xlinker -rpath -Xlinker "$candidate/Library/Developer/usr/lib")
        break
    fi
done

# ${ARGS[@]+...} keeps bash 3.2 (the macOS system bash) from treating an empty array as
# an unbound variable under `set -u`.
exec swift test ${ARGS[@]+"${ARGS[@]}"} "$@"
