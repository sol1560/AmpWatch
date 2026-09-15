# Pushes

The bridge tells the watch when a turn finishes or fails, and (M4) when a tool
call is waiting for a decision. Delivery goes through APNs, so it needs an
Apple push key and a build installed from Xcode or TestFlight. None of that
can run in CI; this page is the manual part.

## How it works

```diagram
┌──────────────┐ agent.end  ┌────────────────────┐  announce  ┌──────────────────┐
│ orb thread X │───────────▶│ plugin instance X  │──POST─────▶│ shared webhook   │
└──────────────┘            └────────────────────┘            │ (one receiver)   │
                                                              └────────┬─────────┘
┌──────────────┐ launch     ┌────────────────────┐  register           │
│ watch        │───────────▶│ WebhookPromptSink  │──POST──────────────▶│
└──────────────┘            └────────────────────┘                     ▼
        ▲                                                    ┌──────────────────┐
        │  APNs alert (category THREAD_DONE / THREAD_ERROR)  │ Pusher (curl h2) │
        └────────────────────────────────────────────────────┤ apns.ts          │
                                                             └──────────────────┘
```

- Every orb thread of the project loads `Plugin/amp-watch-bridge.ts`. On
  `agent.end` it POSTs an `announce` to the shared webhook URL.
- Amp delivers every event on that URL to one plugin instance (the first to
  register; see `docs/DESIGN.md`). That instance keeps the device tokens the
  watch sent with `register` and sends the push.
- Registrations are in memory only. The watch re-registers on every launch;
  nothing is stored on a server.
- `apns-collapse-id` is the thread ID, so the "finished" notification for a
  thread replaces its earlier one instead of stacking.

## One-time setup

1. In the Apple developer portal, create a key with **Apple Push
   Notifications service (APNs)** enabled and download the `.p8` file. Note
   the key ID (10 characters) and your team ID.
2. Give the orb that receives the webhook these variables as Amp project
   secrets (Project settings → Secrets), never as files in the repo:

   | Variable | Value |
   | --- | --- |
   | `APNS_KEY_ID` | the key ID |
   | `APNS_TEAM_ID` | the team ID |
   | `APNS_P8` | the whole `.p8` file; newlines may be typed as `\n` |
   | `APNS_ENV` | `sandbox` for Xcode installs, `production` for TestFlight |

   Then run `amp orb restart-processes` in that thread so the plugin sees
   them. The plugin logs `pushes off; set …` if any is missing.
3. Build the app onto the watch from Xcode (Debug → sandbox) or TestFlight
   (→ production). The `aps-environment` entitlement is in
   `Apps/Watch/AmpWatch.entitlements`; Xcode switches it for release builds.
4. Open the app, allow notifications, and check the plugin log for
   `applied register watch (sandbox)`.

## Checking it end to end

With a token registered, finish any turn in any orb thread of the project.
The plugin log shows `applied announce done ← T-…`; the watch shows the thread
title with the assistant's last line. Tap **Continue** on the notification and
the thread receives `Continue.` as a queued prompt.

If nothing arrives:

- `push failed: HTTP 403` — bad key, key ID or team ID; the provider token is
  rebuilt on the next push.
- `push failed: HTTP 400 … BadDeviceToken` — the build and `APNS_ENV` disagree
  (Xcode install with `production`, or the reverse).
- `device token no longer valid` — the app was removed; relaunch it to
  register again.
- No `announce` line at all — the receiving instance is not the one you
  configured. Only one instance receives; set the variables on that thread's
  orb (the hub, normally).

## What is not done

- A tap on the notification body opens the app to the thread list, not the
  thread. The list is sorted by activity, so the thread is at the top.
- Approval pushes (category `APPROVAL`) arrive only for threads the watch has
  armed from the thread screen ("Ask me first"). The banner's Approve button
  is honoured only for a command the approval screen would not warn about;
  anything flagged, or too long to show whole, opens the screen instead.
  Reject from the banner always goes through.
- The arm level is kept in the thread's plugin memory. When that orb restarts
  the thread is unarmed again, and the picker on the watch will be wrong until
  you set it again.
