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
- Hub role is opt-in by a gitignored marker file in the hub orb
  (`.amp/ampwatch-hub`) so the auto-loaded plugin in other threads does not
  compete for the webhook.
- The `tool.call` handler is a no-op unless the thread has been armed by a
  watch command; otherwise it would intercept the agent's own tool calls in
  every thread of this project, including this one.
- Repo docs stay in English; replies to the owner in Chinese.
- Keychain access uses `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
  (no iCloud sync — the token should not leave the watch).

## Experiment outcomes

(filled in during M2/M3)
