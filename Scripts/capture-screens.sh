#!/usr/bin/env bash
# Renders every screen of the watch app and saves a PNG per screen.
#
# The app reads `-ampwatch-screen <name>` at launch and mounts that screen
# directly against frozen fixture data, so this captures states a happy-path
# walkthrough would never reach (empty, unauthorized) and produces
# byte-stable images across runs.
#
# Usage: Scripts/capture-screens.sh <simulator-udid> <app-bundle-path> <output-dir>
set -euo pipefail

udid=${1:?simulator udid required}
app_path=${2:?path to the built .app required}
out_dir=${3:-.artifacts/screens}

bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${app_path}/Info.plist")
screens=(threads threads-empty threads-error detail compose usage setup settings new-thread)

mkdir -p "$out_dir"

xcrun simctl bootstatus "$udid" -b
xcrun simctl install "$udid" "$app_path"

for screen in "${screens[@]}"; do
  xcrun simctl terminate "$udid" "$bundle_id" >/dev/null 2>&1 || true
  xcrun simctl launch --console-pty "$udid" "$bundle_id" \
    -ampwatch-screen "$screen" >/dev/null 2>&1 &
  launch_pid=$!

  # SwiftUI needs a moment to lay out and the container background to settle.
  sleep 4
  xcrun simctl io "$udid" screenshot --type=png "${out_dir}/${screen}.png"
  kill "$launch_pid" >/dev/null 2>&1 || true
  echo "captured ${screen}"
done

xcrun simctl terminate "$udid" "$bundle_id" >/dev/null 2>&1 || true
echo "Screenshots in ${out_dir}"
