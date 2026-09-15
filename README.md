# AmpWatch

An open-source Apple Watch client for [Amp](https://ampcode.com). Glance at what
your agents are doing, read what they said, and send them a prompt from your
wrist.

Not affiliated with Sourcegraph. Built against Amp's public External API and
public Plugin API.

## Status

Milestone 1. The watch app renders every screen against fixture data, and CI
builds it and screenshots it on a watchOS simulator. Live network wiring is
milestone 2 — see [Roadmap](#roadmap).

## What it does

| Screen | Shows |
| --- | --- |
| Threads | One row per thread: activity dot, title, repo, time since last change; live threads also show spend, flagged past your cap. Anything still waiting to send sits at the top |
| Thread | The transcript, trimmed to what fits a wrist; Stop, Reply, Cost, and "Ask me first" |
| Reply | Dictate or scribble a prompt into a running thread, or tap a saved phrase |
| New thread | Start a thread from a template or a dictated prompt |
| Cost | Thread spend, broken down per model |
| Approve? | A held shell command, with a warning for anything destructive; Approve is missing when the command cannot be shown whole |
| Phrases, Templates | Edit the phrases and templates above, on the watch |

Every send goes through an on-disk outbox first. With no link, the screen
says "saved" instead of failing, and the next raise of the wrist retries in
order. A queued approval older than the bridge's own timeout (10 minutes) is
dropped rather than delivered late.

## How it talks to Amp

Reads and writes go over different channels, because Amp's public surfaces
divide that way:

```diagram
┌───────────┐  GET /api/v2/threads…   ┌──────────────┐
│ AmpWatch  │────────────────────────▶│ ampcode.com  │
│           │       read-only         │ External API │
│           │                         └──────────────┘
│           │  POST capability URL    ┌──────────────┐   appendUserMessage
│           │────────────────────────▶│ plugin       │──────────────────┐
└───────────┘   fire-and-forget       │ webhook (orb)│                  │
                                      └──────────────┘                  ▼
                                                                  your thread
```

- **Read** — `GET /api/v2/threads`, `…/messages`, `…/usage`. Authenticated with
  a machine-to-machine OAuth client created at
  [ampcode.com/workspace/applications](https://ampcode.com/workspace/applications).
- **Write** — the External API has no endpoint that posts to a thread, so
  replies go through [`Plugin/amp-watch-bridge.ts`](Plugin/amp-watch-bridge.ts),
  an Amp plugin that opens one durable webhook and appends the prompt as a user
  message.

### Two limits worth knowing before you file a bug

**There is no agent run state over HTTP.** The API returns `updatedAt` but not
the plugin API's `idle | running | awaiting-approval | error`. So the activity
dot means "changed recently", not "the agent is running". `ThreadActivity`
([AmpKit](Packages/AmpKit/Sources/AmpKit/Model/ThreadActivity.swift)) is named
after what it actually measures, and the UI says "moving" / "quiet" rather than
claiming a run state.

**Replies are fire-and-forget.** The plugin webhook handler returns
`void | Promise<void>`, so a 202 means Amp accepted the prompt for
at-least-once delivery — not that the agent read it. The compose screen says
"queued", not "sent".

## Build it

```bash
brew install xcodegen xcbeautify
xcodegen generate
open AmpWatch.xcodeproj
```

The `.xcodeproj` is generated from [`project.yml`](project.yml) and is not
committed.

Test the platform-neutral core on any machine, including Linux:

```bash
cd Packages/AmpKit && swift test
```

## Verification without a Mac

Every push runs [`.github/workflows/watchos.yml`](.github/workflows/watchos.yml)
on GitHub's standard `macos-15` runner, which is **free for public
repositories** and ships watchOS simulator runtimes. The job builds the app,
runs unit and UI tests on a real watchOS simulator, and uploads a PNG of every
screen — including the empty and unauthorized states — as an artifact.

That means neither you nor an agent needs a Mac to see whether a UI change
looks right:

```bash
gh workflow run watchOS
gh run watch "$(gh run list --workflow=watchOS --limit=1 --json databaseId --jq '.[0].databaseId')"
gh run download "$(gh run list --workflow=watchOS --limit=1 --json databaseId --jq '.[0].databaseId')" --dir .artifacts
```

[`Scripts/pick-watch-simulator.sh`](Scripts/pick-watch-simulator.sh) asks
`simctl` which runtimes exist instead of hard-coding one, because the runner
image's watchOS versions change every few weeks.

## Design

Sampled from ampcode.com: a deep desaturated green-charcoal ground, warm
parchment type (`#DFDFC1`), one ember accent (`#F47B35`), hairline rules,
editorial serif for display type over plain sans for body. The watch canvas is
pure black rather than Amp's `#10201c` — on OLED a near-black fill is visibly
lit in a dark room and costs battery in always-on mode.

## Roadmap

1. ~~Fixture-backed UI, rendered and screenshotted in CI~~
2. ~~Live `AmpAPIClient` + `WebhookPromptSink` wiring, credentials in the Keychain~~
3. ~~Push notifications from the plugin (`docs/PUSH.md`)~~
4. ~~Approvals: arm a thread from the watch, decide held shell commands~~
5. ~~Offline outbox, saved phrases, thread templates, a spend cap~~
6. Complication and background refresh, so the wrist shows thread activity
   without opening the app

## Licence

MIT. See [LICENSE](LICENSE).
