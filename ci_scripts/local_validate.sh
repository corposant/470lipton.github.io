#!/bin/sh
# Run on the developer's Mac with Xcode + XcodeGen. This has not run in Linux.
# Usage: sh ci_scripts/local_validate.sh '<xcodebuild destination>' '<new result bundle path>'
set -eu
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 '<xcodebuild destination>' '<new .xcresult path>'" >&2
    exit 2
fi
command -v xcodebuild >/dev/null
command -v xcodegen >/dev/null
cd "$(dirname "$0")/.."
xcodegen generate
xcodebuild -project Nog.xcodeproj -scheme Nog -destination "$1" \
    -resultBundlePath "$2" test
