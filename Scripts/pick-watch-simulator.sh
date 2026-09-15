#!/usr/bin/env bash
# Picks a watchOS simulator that is actually installed on this machine.
#
# GitHub's macOS runner images add and remove simulator runtimes constantly:
# the "Installed SDKs" table in the image README lists far more watchOS
# versions than the "Installed Simulators" table, and a workflow that hard-codes
# a runtime fails weeks later with an opaque "Unable to find a destination"
# error. So: ask simctl, prefer the newest runtime and the largest screen, and
# fail loudly with the full inventory when nothing matches.
#
# Prints `UDID<TAB>NAME<TAB>RUNTIME` on stdout.
set -euo pipefail

devices_json=$(xcrun simctl list devices available --json)

selection=$(printf '%s' "$devices_json" | jq -r '
  [ .devices
    | to_entries[]
    | select(.key | test("watchOS"))
    | .key as $runtime
    | (.key | capture("watchOS-(?<major>[0-9]+)-(?<minor>[0-9]+)")
            | (.major | tonumber) * 1000 + (.minor | tonumber)) as $rank
    | .value[]
    | select(.isAvailable)
    | { udid, name, runtime: $runtime, rank: $rank,
        # `capture` yields nothing when the name has no size, which would drop
        # the device from the list entirely. Default it instead, so an
        # unfamiliar device is merely deprioritised rather than invisible.
        size: ((.name | capture("(?<mm>[0-9]+)mm") | .mm | tonumber) // 0) }
  ]
  | sort_by(.rank, .size)
  | last
  | if . == null then empty else "\(.udid)\t\(.name)\t\(.runtime)" end
')

if [[ -z "${selection}" ]]; then
  echo "No available watchOS simulator on this machine." >&2
  echo "Runtimes and devices simctl reports:" >&2
  printf '%s' "$devices_json" | jq -r '.devices | keys[]' >&2
  exit 1
fi

printf '%s\n' "$selection"
