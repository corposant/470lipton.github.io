#!/bin/sh
set -e

# 1. Add Homebrew to PATH (Apple Silicon / Intel)
if [[ -d "/opt/homebrew/bin" ]]; then
    export PATH="/opt/homebrew/bin:$PATH"
elif [[ -d "/usr/local/bin" ]]; then
    export PATH="/usr/local/bin:$PATH"
fi

# 2. Navigate to repository root
cd "$CI_PRIMARY_REPOSITORY_PATH"

# 3. Install and run xcodegen
brew install xcodegen
xcodegen
