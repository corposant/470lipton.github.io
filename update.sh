#!/bin/sh
# Pull the latest Nog and regenerate the Xcode project (picks up any new files).
set -e
cd "$(dirname "$0")"
git pull
xcodegen
echo "Up to date. If Xcode asks, choose Read From Disk, then build (⌘B)."
