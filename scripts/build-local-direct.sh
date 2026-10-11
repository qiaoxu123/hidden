#!/bin/zsh
# Build the macOS 27 hiding engine for local use, without App Sandbox.
set -euo pipefail

repo_dir="${0:A:h:h}"
derived_data="$repo_dir/build"
app_path="$derived_data/Build/Products/Release-Direct/Hidden Bar.app"

xcodebuild -project "$repo_dir/Hidden Bar.xcodeproj" \
  -scheme 'Hidden Bar' -configuration Release-Direct \
  -derivedDataPath "$derived_data" CODE_SIGNING_ALLOWED=NO build

# Ad-hoc signing makes this a runnable local build; it is not a notarized release.
codesign --force --deep --sign - "$app_path"
codesign --verify --deep --strict "$app_path"

entitlements_file="$(mktemp)"
trap 'rm -f "$entitlements_file"' EXIT
codesign -d --entitlements "$entitlements_file" "$app_path"
if [[ -s "$entitlements_file" ]] && \
   [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$entitlements_file" 2>/dev/null || true)" == true ]]; then
  print -u2 'Refusing sandboxed build: macOS 27 hiding requires the Direct configuration.'
  exit 1
fi
if ! /usr/bin/grep -aFq '/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore' \
    "$app_path/Contents/MacOS/Hidden Bar"; then
  print -u2 'The native macOS 27 visibility engine is missing from this build.'
  exit 1
fi

print "Local Direct build ready: $app_path"
print 'Quit any installed Hidden Bar, copy this app to /Applications, then enable Accessibility for it.'
