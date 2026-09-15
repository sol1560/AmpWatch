# Decisions

## Frontmatter (resolved)

auto_approve_plan=true, use_cross_review=true, use_rescue=true,
adversarial_each_milestone=false, adversarial_final=true, use_test_agent=true
(backend: GitHub Actions `watchOS` workflow), max_parallel_features=2.

## Environment

- Orb on Linux; Swift 6.2 toolchain at
  `/home/user/toolchains/swift-6.2-RELEASE-debian12/usr/bin`; `bun`, `gh`
  (Amp GitHub App token, can push to `sol1560/AmpWatch` but not create repos).
- No macOS here. All watchOS builds and screenshots come from CI on
  `macos-15` (simulator: Apple Watch Ultra 2 49mm, watchOS 26.2). A run takes
  about 7 minutes.
- Remotes: `github` (GitHub, tracked by `main`) and `origin` (Amp project).

## Product / architecture

- Cloud-only: watch ↔ Amp External API v2 (reads) and one webhook owned by a
  hub orb thread (writes). No phone, no laptop in the loop.
- The plugin only ever acts on threads the watch names by ID; it never
  enumerates threads on its own.
- Every plugin instance registers `amp-watch` with the same handler (Amp
  delivers to one of them; measured). The gitignored marker file
  `.amp/ampwatch-hub` only decides which orb writes the URL file. Earlier
  plan (only the hub registers) was dropped in M3: non-hub instances need the
  URL to announce their turn outcomes, and a no-op receiver would lose events.
- Pushes: only `agent.end` is announced (one event per turn), not
  `agent.start`, to keep within the 10/min webhook budget shared with watch
  commands. `cancelled` is not pushed (the user asked for it).
- APNs credentials are Amp project secrets read from `process.env`
  (`APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_P8`, `APNS_ENV`); never files.
- Notification tap opens the list, not the thread (no deep link yet).
- The `tool.call` handler is a no-op unless the thread has been armed by a
  watch command; otherwise it would intercept the agent's own tool calls in
  every thread of this project, including this one.
- Repo docs stay in English; replies to the owner in Chinese.
- Keychain access uses `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
  (no iCloud sync — the token should not leave the watch).

## Experiment outcomes

- Webhook ownership (2026-09-15, threads A=T-01a0a325…, B=T-01a0a3cd…): shared
  key → same URL, delivered to the first registrant only, sticky across
  re-registration. Per-thread key → distinct URL, delivered to that thread.
  Plugin cwd is `.amp/plugins`. Details in docs/DESIGN.md.
- Consequence: M3 becomes pushes (APNs), M4 becomes approvals; the watch talks
  only to the hub, which forwards decisions to per-thread approval webhooks.
- `tool.call` ceiling (2026-09-15, thread B): handler slept 2/5/10/20 min,
  all succeeded, no ceiling found. Approval timeout is therefore a product
  choice; set to 10 min on both sides (`APPROVAL_TIMEOUT_MS`,
  `Outbox.decisionTTL`). Veto-able.
- M6: the widget extension reads a file (`Glance`) in the app group; it holds
  no credential and never fetches. "Awaiting you" = approval notifications
  still delivered and younger than the decision window. "Spend today" = sum
  of usage for threads changed since local midnight, and the list now
  fetches usage for those threads too (was: live only). Always-on: ember
  only on the approval screen; transcript and command text `privacySensitive`.
