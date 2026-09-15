---
auto_approve_plan: true
use_cross_review: true
use_rescue: true
adversarial_each_milestone: false
adversarial_final: true
use_test_agent: true
test_agent_backend: auto
max_parallel_features: 2
---

# AmpWatch mission

Build the open-source Apple Watch client for Amp described in `docs/DESIGN.md`,
to the point where the owner (a student, Apple Watch Ultra, school Wi-Fi, no
phone or laptop in reach for hours) can read, prompt, cancel, create and
approve from the wrist against real Amp threads running in orbs.

`docs/DESIGN.md` is the source of truth for architecture and priorities. This
file only fixes scope and acceptance for the autonomous run.

## Fixed constraints

- Swift 6, SwiftUI, no third-party Swift dependencies. XcodeGen project.
- Logic lives in `Packages/AmpKit` and is tested with `swift test` on Linux.
  Views stay thin. Every screen has an `accessibilityIdentifier` and a
  `ScreenshotScene` entry, and is listed in `Scripts/capture-screens.sh`.
- The plugin lives in `Plugin/` (source of truth) and is copied to
  `.amp/plugins/` so it auto-loads in project orbs. Pure logic is separated
  from the `PluginAPI` surface and tested with `bun test`.
- Nothing in the repo may contain a token, secret, webhook URL or device token.
- UI verification is the GitHub Actions workflow `watchOS` on the free
  `macos-15` runner: `gh workflow run` / push, then download and **inspect**
  the screenshot artifact. A UI change is not done until its screenshot has
  been looked at.
- The approval screen must never auto-approve, never silently truncate, and
  must default to Defer when the input is not fully readable.
- Do not push anywhere except `github` (`sol1560/AmpWatch`) and `origin`
  (the Amp project repo); both were explicitly authorized by the owner.

## Milestones

### M1 — Real reads on the watch

The watch stores a read-only External API token in the Keychain, entered on
a Settings screen, and renders the owner's real threads, messages and usage
through `AmpAPIClient`. Without a token it shows a setup screen, not an
error. Fix the two issues seen in the first screenshots: error copy still
mentions "the phone app"; the detail title scrolls in the navigation bar.

### M2 — Hub plugin and writes

The bridge plugin accepts JSON commands (`prompt`, `steer`, `cancel`,
`create`) on one durable webhook owned by a designated hub thread, validates
them, deduplicates by `event.id`, and applies them via `amp.threads.get(id)`.
The watch's Settings screen takes the webhook URL; Compose sends prompts and
the detail screen can cancel. First, run the **webhook ownership
experiment**: with the plugin loaded in two threads of this project that
both register the same key, determine which thread's handler receives a
POST, whether the URL is identical, and whether a POST reaches a paused
orb. Write the result into `docs/DESIGN.md` and adapt M3 to it.

### M3 — Pushes

The plugin sends APNs pushes through the orb's `curl --http2` using
credentials from environment variables (never files in the repo). Pushes
carry agent state transitions and approval requests. The watch registers
for remote notifications, stores its device token, and offers notification
actions Approve / Reject / Continue. End-to-end delivery needs the owner's
`.p8` key and cannot be exercised in CI; the push-building code is unit
tested and the manual steps are documented in `docs/PUSH.md`.

### M4 — Approvals

The plugin's `tool.call` handler, when the thread is armed for watch
approvals, reports the pending call and awaits a decision delivered through
a per-thread webhook key (`approve-<threadID>`), forwarded by the hub. The watch shows an
approval screen built on `PendingApproval.recommendation()`; Approve is
absent when the recommendation is `deferToLargerScreen`. The pending-handler
ceiling is measured with a deliberately slow handler and written down; on
timeout the handler returns `reject-and-continue` with a stated reason.

### M5 — Working offline and faster

The `Outbox` actor is wired into Compose and Approve so that prompts and
decisions written without connectivity are delivered in order, exactly
once, when the network returns; decisions older than the TTL are dropped
with a visible note. Saved phrases and thread templates (repo + agent mode
+ opening prompt) are editable on the watch. A per-thread budget guard
warns at a configurable dollar cap.

### M6 — Polish

Complications for "threads awaiting you" and today's spend; VoiceOver
labels on every interactive element; always-on rendering keeps the ember
accent only for blocked threads. Battery measurement is a manual check.

## Out of scope

Reading diffs or code on the watch; an iOS companion app; controlling
threads that run in a local CLI rather than an orb; App Store submission.
