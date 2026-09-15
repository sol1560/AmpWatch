# Plan

Milestones follow `spec.md`. Features are the unit of work; each ends with a
programmatic check and, where a screen changes, an inspected CI screenshot.

## M1 — Real reads on the watch

- F1.1 `SecretStore` protocol in AmpKit (`token`, `webhookURL`, `deviceToken`)
  with an in-memory implementation for tests/fixtures; `KeychainSecretStore`
  in the watch app.
- F1.2 `AmpEnvironment.live()` builds `AmpAPIClient(URLSessionTransport,
  StaticAccessToken)` and `WebhookPromptSink` from the store; without a
  token the root view is `SetupView`.
- F1.3 `SettingsView` (token field, webhook URL field, clear, version) reachable
  from the thread list; `ScreenshotScene.settings` and `setup`.
- F1.4 Error copy: no "phone app"; unauthorized → "Open Settings and paste a
  new token". Detail title: fixed short nav title, full title inline.
- Gate: `swift test` green; CI green; screenshots `setup`, `settings`,
  `threads-error` inspected.

## M2 — Hub plugin and writes

- F2.0 Ownership experiment (two project threads, same key). Result →
  `docs/DESIGN.md` §Unknowns.
- F2.1 `Plugin/commands.ts`: pure `parseCommand(body)` → discriminated union
  or error; `bun test`.
- F2.2 `Plugin/amp-watch-bridge.ts`: hub registration gated by marker file
  `.amp/ampwatch-hub`; dedup by `event.id` (bounded set); apply commands.
- F2.3 Watch: `AmpPromptSink` gains `cancel(threadID)` and `create(...)`;
  Compose posts through the sink; detail gets Cancel; Settings gets the URL.
- Gate: `bun test` green; plugin loads in this orb without errors; CI green.

## M3 — Pushes

- F3.1 `Plugin/apns.ts`: JWT (ES256 via `crypto.subtle`) + payload builders;
  tested. Send via `amp.$` `curl --http2` with a curl config file.
- F3.2 Bridge: `register` and `announce` commands; every instance announces
  its own `agent.end`; the receiver pushes to registered tokens.
- F3.3 Watch: `PushRegistrar` (WKApplicationDelegate + notification
  categories with actions), device token stored and re-sent per launch;
  `docs/PUSH.md`.
- Gate: `bun test`, `swift test`; round trip through the real webhook in the
  orb; fake-key probe against Apple's sandbox gateway; CI build green.

## M4 — Approvals

- F4.1 `Plugin/approvals.ts`: pure queue (`pending`, `resolve`, `expire`).
- F4.2 `tool.call` handler armed per thread; per-thread key `approve-<threadID>`,
  URL announced to the shared webhook; receiver forwards `decide`; approval push.
- F4.3 `ApprovalView` on the watch driven by `PendingApproval.recommendation()`;
  `ScreenshotScene.approval`, `approval-deferred`, `approval-destructive`.
- F4.4 Ceiling measurement with a slow handler; recorded in DESIGN.md.
- Gate: `bun test`, `swift test`, CI screenshots inspected.

## M5 — Offline and faster

- F5.1 Outbox wired into Compose/Approve; TTL drop with note.
- F5.2 Saved phrases + thread templates (`UserDefaults`-backed store in
  AmpKit, editable on watch). Scenes `phrases`, `templates`.
- F5.3 Budget guard (`ThreadUsage` vs cap) in detail and list.
- Gate: tests + inspected screenshots.

## M6 — Polish

- F6.1 Complications (WidgetKit) — build-only in CI.
- F6.2 VoiceOver labels; always-on reduced accent.
- Gate: CI green, screenshots inspected, final adversarial review.
