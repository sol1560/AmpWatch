# Acceptance contract

Two kinds of checks. **Programmatic**: commands that must exit 0.
**UX**: CI screenshots that a reviewer (this agent, via `view_media`) must
confirm show the stated content. A feature is done only when both hold.

## Global

- `cd Packages/AmpKit && swift test` exits 0.
- `cd Plugin && bun test` exits 0 (from M2).
- Workflow `watchOS` on `github/main` is green and uploads `screens`.
- `git grep -nE 'amp_[a-z]+_[A-Za-z0-9]{20,}|hooks/|BEGIN PRIVATE KEY'` finds
  nothing in tracked files.

## M1

- P: `AmpKitTests` cover `SecretStore` round-trip and `AmpEnvironment`
  selection (token present → live client; absent → setup).
- UX: `setup.png` shows a headline, one-line explanation and a "Paste token"
  control with no error styling. `settings.png` shows masked token state,
  webhook URL state, and a "Sign out" action. `threads-error.png` no longer
  mentions a phone. `detail.png` shows the full title as body text and a
  short non-scrolling nav title.

## M2

- P: `bun test` covers: all four commands parse; unknown `type` rejected;
  missing `threadID` rejected; `prompt` > 4000 chars rejected; duplicate
  `event.id` ignored.
- P: `amp plugins list` in this orb shows `amp-watch-bridge` loaded with no
  error after `load_plugin`.
- P: Experiment results recorded in `docs/DESIGN.md` with the thread IDs used.
- UX: `compose.png` unchanged in layout; `detail.png` shows a Cancel action
  only when the fixture thread is `running`.

## M3

- P: `bun test` covers queue expiry and duplicate resolution; `swift test`
  covers `recommendation()` for the three fixtures below.
- UX: `approval.png` (short `ls -la`) shows Approve / Reject / Defer;
  `approval-destructive.png` (`rm -rf build`) shows a warning and Approve
  requires a second confirmation; `approval-deferred.png` (700-char input)
  shows no Approve button and a "too long to read here" note.

## M4

- P: `bun test` covers ES256 JWT header/claims and payload builders for
  `state`, `approval`.
- P: watch target builds with the notification entitlement in CI.
- Manual (documented, not gated): a real push arrives on the owner's watch.

## M5

- P: `swift test` covers Outbox ordering, single delivery, TTL drop.
- UX: `phrases.png`, `templates.png`, and `detail.png` with a budget warning.

## M6

- P: CI builds the complication extension.
- UX: `complication` screenshots if the harness can render them; otherwise the
  build is the gate and this is recorded as a limitation.
