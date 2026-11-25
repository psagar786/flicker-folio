#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

output="${1:-./dist}"
mkdir -p "$output"
output="$(cd "$output" && pwd)"
build_dir="$(mktemp -d)"
trap 'rm -rf "$build_dir"' EXIT
bundle="$build_dir/Flicker Folio.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"

target="$(uname -m)-apple-macos15.0"
xcrun swiftc -target "$target" -module-cache-path "$PWD/.module-cache" -swift-version 5 -O -emit-library -static \
  -emit-module-path "$build_dir/NotchPrompterKit.swiftmodule" -module-name NotchPrompterKit \
  NotchPrompterKit/Sources/NotchPrompterKit/*.swift -o "$build_dir/libNotchPrompterKit.a"
xcrun swiftc -target "$target" -module-cache-path "$PWD/.module-cache" -swift-version 5 -O -I "$build_dir" -L "$build_dir" \
  -lNotchPrompterKit NotchPrompter/*.swift -o "$bundle/Contents/MacOS/FlickerFolio"

cp Config/Info.plist "$bundle/Contents/Info.plist"
cp NotchPrompter/PrivacyInfo.xcprivacy Config/FlickerFolio.icns LICENSE README.md PRIVACY.md "$bundle/Contents/Resources/"
codesign --force --sign - --identifier app.notchpick.local "$bundle"
codesign --verify --strict "$bundle"
ditto "$bundle" "$output/Flicker Folio.app"
printf 'Built %s\n' "$output/Flicker Folio.app"
