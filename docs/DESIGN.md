# AmpWatch — design

## Thesis

The watch is a **discreet control surface** for agents that are already
running in Amp orbs, usable during the hours when the laptop and the phone are
off-limits. The goal is *control*, not *awareness*:

> Keep me in the loop with my agents, and let me unblock them, from my wrist.

## Everything runs in the cloud; no laptop, no phone

Two facts settle the architecture:

1. `amp.createWebhook` **only works inside a plugin running in an Amp-managed
   orb**. It is not available to local CLI plugins. So the bridge that turns
   watch taps into agent actions must live in an orb, not on the laptop.
2. The school Wi-Fi is WPA (password), not captive. The watch can join it on
   its own. There is no need for the iPhone to relay anything.

So there is exactly one piece of infrastructure, and Amp already hosts it: a
**hub thread** in this project whose plugin does the bridging.

```diagram
┌─────────────┐  HTTPS (read)   ┌──────────────────────────────┐
│ Apple Watch │───────────────▶ │ ampcode.com External API v2   │
│  on Wi-Fi   │                 │  threads · messages · usage   │
│             │  POST (write)   └──────────────────────────────┘
│             │───────────────▶ ┌──────────────────────────────┐
│             │                 │ webhook → hub-thread plugin   │
│             │ ◀────────────── │  amp.threads.get(id)          │
└─────────────┘  APNs (alerts)  │   .state / .appendUserMessage │
                                │   .cancel / createThread      │
                                │  keepAlive() while in session │
                                └──────────────┬───────────────┘
                                               │ controls
                                               ▼
                                ┌──────────────────────────────┐
                                │ your other orb threads        │
                                │ (opened from ampcode.com)     │
                                └──────────────────────────────┘
```

Scope consequence, stated plainly: **AmpWatch controls threads that run in
orbs.** Threads driven by a local CLI on the laptop are out of reach of a
cloud plugin. For a student working from the web UI that is the whole
population.

## What each leg does

**Reads — External API v2, directly from the watch.** `GET /threads`,
`GET /threads/{id}/messages`, `GET /threads/{id}/usage` with a bearer token
from a workspace M2M application. The token lives in the watch Keychain. This
is read-only by construction; the API has no write endpoints for threads, so a
leaked token cannot make an agent do anything.

**Writes — one webhook, owned by the hub plugin.** Every command is a small
signed JSON POST: `prompt`, `steer`, `cancel`, `create`, `approve`, `reject`,
`defer`. The handler returns nothing (the API is `void`), so the watch never
waits on it for data; it learns the outcome from the next read or the next
push. Rate limit is a burst of 10 and 10/min refill, plenty for a wrist.

**State and alerts — APNs, sent by the plugin.** The External API exposes no
run state. The plugin does: `thread.state` is
`idle | running | awaiting-approval | error`. The hub subscribes to the
threads it knows about and pushes on every transition. Pushes carry the state
and, for approvals, the tool name and input (APNs payload limit is 4 KB, so
long inputs are truncated *with a flag*, never silently). Sending APNs needs
HTTP/2; rather than rely on the plugin runtime's `fetch`, the plugin shells
out with `amp.$` to the orb's `curl --http2`, which is known to work.

## The plugin API, verified from the type definitions

| Need | API |
| --- | --- |
| Real agent state | `amp.threads.get(id).state` — `Observable<ThreadState>` with `get()` |
| Approve / reject / modify a tool call | `tool.call` handler returns `allow`, `reject-and-continue`, `modify`, `synthesize` |
| Stop a runaway turn | `thread.cancel()` |
| Start new work | `agent.createThread(...)`, `amp.getBuiltinAgent(mode)` |
| Steer a busy thread | `appendUserMessage(msg, { steer: true })` |
| Receive commands | `amp.createWebhook({ key, handler })`, 30 s deadline, at-least-once |
| Stay awake | `amp.executor.keepAlive()` — renews a lease, costs orb credits |
| Send pushes | `amp.$\`curl --http2 ...\`` |

Checked in at `.amp/plugins/`, the bridge loads in every orb thread of the
project. Only the hub thread turns on `keepAlive()` and the webhook; the other
threads' plugin instances handle their own `tool.call` events.

## Approvals: the flow and the two things not yet measured

Webhook handlers get 30 s, so they cannot block waiting for a human. The
`tool.call` handler is what blocks; the webhook only resolves it.

```diagram
thread X: tool.call fires
   └─▶ plugin pushes "awaiting approval" (tool + input) to the watch
   └─▶ handler awaits a decision
                                        watch shows it, you tap Approve
                                             └─▶ POST webhook { approve, callID }
   decision reaches thread X's handler ◀─────────┘
   └─▶ returns { action: 'allow' }
```

**Unknown 1 — webhook ownership. Measured 2026-09-15.** Two orb threads of
this project (A = `T-01a0a325-7a11-73eb-a5a7-46c40b37076d`, B =
`T-01a0a3cd-4f9f-74a0-aaec-54300f07549c`) both registered key `amp-watch`.

- Both received byte-identical capability URLs (same SHA-256).
- A registered first. Two POSTs made *by B* (before and after A re-registered)
  were both handled by **A's** handler; B's handler never fired. Ownership is
  sticky to the first registrant and re-registration does not move it.
- A key that only B registered (`exp-per-thread-b`) produced a **different**
  URL and its events were delivered to **B's** handler.
- The plugin process's working directory is `.amp/plugins`, not the workspace
  root; use `amp.system.workspaceRoot` for paths.

Consequence: all instances register `amp-watch` with one shared handler, and
one of them receives; approvals use a per-thread key `approve-<threadID>`
whose URL only that thread's handler receives. The per-thread instance tells
the receiver its approval URL by POSTing to the shared URL, the same way it
announces turn outcomes. The watch only ever talks to the shared URL; the
receiver forwards decisions. No external store is needed.

Not measured: what happens to ownership when the owning orb is paused or
archived. Until it is, the hub thread stays awake during use (see cost note).

**Unknown 2 — how long a `tool.call` handler may stay pending.** Not
documented, so measured (thread B, 2026-09-15): a `tool.call` handler that
slept 2, 5, 10 and 20 minutes before returning `{}` succeeded every time
(20-minute probe: start 07:27:32Z, end 07:47:32Z, tool ran). No ceiling was
found; at least 20 minutes is safe. The bridge therefore answers on its own
clock, `APPROVAL_TIMEOUT_MS` in `Plugin/amp-watch-bridge.ts` (10 minutes, a
product choice), with `reject-and-continue` and a message that tells the
agent not to retry; the outcome is always the bridge's, never Amp's.
Verified in this orb with the earlier 4-minute value: a held `shell_command`
with no decision came back as "Tool rejected by plugin: Nobody approved this
from the watch within 4 minutes", and the turn continued. The watch drops a
queued decision older than the same window (`Outbox.decisionTTL`).

**Approvals as built (M4).** A thread is *unarmed* until the watch sends
`{ "type": "arm", "level": "off" | "risky" | "all" }` for it. `risky` holds
shell commands whose text matches `DESTRUCTIVE_PATTERNS` (the same list the
watch warns about — a test keeps the two in step); `all` holds every shell
command; edits, reads and searches are never held. The level lives in the
thread's plugin instance memory; it resets when that orb restarts, and the
thread screen says so. Round trip measured in this orb: `arm` → forwarded to
`approve-<threadID>` → `tool.call` held → `announce awaiting-approval` →
`decide approve` from the shared URL → forwarded → the command ran, about a
minute end to end with log latency; `decide reject` → "Rejected from the
watch", the command did not run.

**Unknown 3 — does a webhook delivery resume a paused orb?** If yes, the hub
needs no `keepAlive()` and costs nothing between commands. If no, the hub holds
the lease during school hours and releases it after. Still open.

**Ordering change.** Because the watch can only learn about a pending
approval (and its ID) through a push, APNs moves ahead of approvals:
M3 = pushes, M4 = approvals.

## Features, by whether they keep you in control

**Tier 1 — without these, "control" is a lie**

- Thread list with **real** state, blocked-on-you threads first
- Read the transcript, newest first
- Send a prompt / steer a running thread
- **Approve, reject, or defer a pending tool call**
- Cancel the current turn

**Tier 2 — the difference between coping and working**

- Start a thread from a saved template (repo + agent mode + opening prompt)
- Budget guard: warn, then auto-cancel, past a per-thread dollar cap
- **Offline outbox** — compose while disconnected, deliver in order, once,
  when Wi-Fi returns; decisions expire so a stale approval cannot fire later
- Notification actions (`Approve` / `Reject` / `Continue`) that act without
  opening the app

**Tier 3 — ambient**

- Complications: threads running · **threads awaiting you** · today's spend
- Handoff to the laptop via `NSUserActivity`

### Input

Dictation needs network and is conspicuous. In order of expected use: **saved
phrases**, Scribble, the watch keyboard, then dictation.

## The approval screen is a security surface

- Monospace, scrollable, **never truncated without saying so**
- Destructive patterns (`rm -rf`, force push, `DROP TABLE`, credential paths)
  flagged before you can approve
- When the input does not fit, the default action is **Defer**, not Approve
- No auto-approval, ever. No "approve all".
- If the last push is older than the decision TTL, the button is absent, not
  disabled-looking-clickable — the watch may be looking at a stale request

## Architecture

```diagram
        ┌──────────────────────┐
        │ Watch app (SwiftUI)  │  thin views · Keychain · outbox · APNs receiver
        └──────────┬───────────┘
                   │
                AmpKit   shared, platform-neutral, tested on Linux:
                   │     models · API client · approval rules · outbox · ranking
        ┌──────────┴───────────┐
        ▼                      ▼
  External API v2        .amp/plugins/amp-watch-bridge.ts
  (reads)                webhook · state fan-out · APNs · tool.call
```

`AmpKit` builds and tests on Linux, so the logic that can lie — approval
rules, exactly-once outbox, ranking — is verified in an orb without a Mac.
Views stay thin on purpose.

## Milestones

Each ends with CI screenshots as its reviewable artifact.

| # | Scope | Done when |
| --- | --- | --- |
| **M0** ✅ | Fixture UI, CI builds + screenshots on a watchOS simulator | Done |
| **M1** | Real reads | Watch shows your real threads and messages over school Wi-Fi with a read-only token |
| **M2** | Hub plugin + writes | `prompt`, `cancel`, `create` from the watch reach a real orb thread via the webhook |
| **M3** | Pushes | `done` / `error` arrive on the wrist via APNs from the plugin; notification actions work |
| **M4** | **Approvals** | Approve a real tool call from the watch; unknowns 1–2 above measured and written down |
| **M5** | Outbox + templates + budget guard | Three prompts written in airplane mode arrive in order, exactly once |
| **M6** | Battery + polish | Measured drain across a real school day; complications; VoiceOver |

M1 is first because it is the smallest thing that proves the watch, the Wi-Fi
and the token work together, and it needs no plugin.

## What "correct" means

The dangerous bugs here are **lies**, not crashes:

- An approval that says it went through when the handler had already timed out
- A queued prompt delivered twice after a reconnect
- An approve button shown for a request that is no longer pending
- A truncated command presented as if it were complete
- A stale `idle` shown while the thread is actually blocked on you

Each gets a test in `AmpKit`, where it runs without a simulator.

## Open questions

1. **Watch model?** Series 5 / SE are 2.4 GHz only; cellular would work even
   off the school network.
2. **Hub cost tolerance.** If unknown 3 says webhooks do not wake a paused
   orb, `keepAlive()` burns credits for the whole school day. Acceptable?

## Non-goals

- Reading or writing code, viewing diffs. The laptop is always with you.
- Controlling local-CLI threads on the laptop. Cloud plugin cannot reach them.
- Holding a write-capable workspace credential on the watch. Writes go through
  the webhook, whose URL is the only secret with power, and it is scoped to
  the commands the plugin chooses to accept.
