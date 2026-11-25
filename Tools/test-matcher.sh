#!/bin/zsh
# Compiles and runs the VoiceMatcher regression tests.
set -e
cd "$(dirname "$0")/.."

test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
target="$(uname -m)-apple-macos15.0"

xcrun swiftc -target "$target" -module-cache-path "$test_dir/module-cache" -O \
  Tools/MatcherTests/main.swift NotchPrompterKit/Sources/NotchPrompterKit/VoiceMatcher.swift \
  -o "$test_dir/matcher"
"$test_dir/matcher"
