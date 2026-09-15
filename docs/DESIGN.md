# AmpWatch — design

## Thesis

You have a laptop and your iPhone is one room away. So the watch is not a
replacement for either — it is a **discreet control surface** for agents that
are already running, usable during the hours when picking up the laptop or the
phone is not an option.

That makes the design goal *control*, not *awareness*:

> Keep me in the loop with my agents, and let me unblock them, from my wrist.

The previous draft assumed the watch was alone and had to be a read-mostly
glance device. It is not alone. The phone next door changes the architecture.

## The phone is the broker

Apple's documentation settles this: calling `sendMessage` from a watch app
**wakes the counterpart iOS app in the background** and makes it reachable. The
watch and the iPhone also stay connected over Wi-Fi when Bluetooth is out of
range.

So the iPhone — sitting untouched next door — becomes the piece of
infrastructure this app needed and I previously proposed building on
Cloudflare:

```diagram
┌───────────────┐
│ Apple Watch   │  UI only. No credentials. No API knowledge.
└───────┬───────┘
        │ WCSession sendMessage  (wakes the phone app in the background)
        ▼
┌───────────────┐
│ iPhone        │  The broker. Never touched.
│  · Keychain   │  · holds the workspace credential
│  · API calls  │  · does every read
│  · webhook    │  · does every write
│  · local notif│  · alerts mirror to the watch automatically
└───────┬───────┘
        │ HTTPS
        ▼
┌──────────────────────────────┐
│ ampcode.com  +  orb plugin   │
└──────────────────────────────┘
```

Three problems disappear at once:

1. **Credentials leave the watch.** The workspace-scoped M2M secret lives in the
   iPhone Keychain, which is the right place for it. No Cloudflare Worker, no
   custom broker, no token-narrowing scheme — for v1.
2. **Alerts need no push server.** An iOS local notification is mirrored to the
   watch by the system when the watch is on your wrist and the phone is locked.
   That is exactly the state your phone is in. Free alert channel.
3. **The watch stops needing its own internet.** Bluetooth or same-network
   Wi-Fi to the phone is enough, and the phone carries the connection.

### Degraded modes, in order

| Situation | Behaviour |
| --- | --- |
| Phone reachable (normal) | Everything through the phone |
| Phone out of range | Watch falls back to direct HTTPS with a narrow token; read + prompt only, no approvals |
| School Wi-Fi is captive and the watch cannot join | Watch still reaches the phone over Bluetooth; degraded but working |
| Neither | Offline queue: compose now, send when a link returns |

The watch must show which mode it is in. Silently degrading from "approvals
work" to "approvals do not work" is the kind of lie this app must not tell.

## What the plugin API actually allows

I read the real type definitions in an orb, and my earlier design badly
underestimated them. The External API is read-only and exposes no run state,
but a **plugin does**:

| Capability | API |
| --- | --- |
| Real agent state | `thread.state: Observable<'idle' \| 'running' \| 'awaiting-approval' \| 'error'>` |
| **Approve / reject / modify tool calls** | `tool.call` handler returns `allow`, `reject-and-continue`, `modify`, or `synthesize` |
| Stop a runaway turn | `thread.cancel()` |
| Start new work | `Agent.createThread`, `getBuiltinAgent(mode)` |
| Receive commands from outside | `amp.createWebhook(...)`, 30 s handler deadline |
| Steer a busy thread | `appendUserMessage(msg, { steer: true })` |

`awaiting-approval` is the important one. **Approving a tool call from your
wrist is the feature that makes this worth building**, and it is the thing that
most often blocks an agent while you are away from the keyboard.

Checked in at `.amp/plugins/`, the bridge loads automatically in every orb
thread for that project — no per-thread setup.

### The one hard constraint

Webhook handlers get **30 seconds**, then they are aborted and retried. So the
webhook cannot block waiting for you to approve something. The flow inverts:

```diagram
tool.call fires
   └─▶ plugin reports "awaiting approval" upstream, then awaits a promise
                                   │
   watch shows it ◀────────────────┘
        │
   you tap Approve
        │
        └─▶ phone POSTs the webhook (returns in milliseconds)
                 └─▶ handler resolves the pending promise
                          └─▶ tool.call returns { action: 'allow' }
```

**Unknown:** how long a `tool.call` handler may stay pending before Amp gives
up. Not documented. This is the single biggest technical risk in the plan and
gets measured first in M3. If the ceiling is short, approvals degrade to
"approve the next tool call of this kind", decided in advance.

## Features, by whether they keep you in control

**Tier 1 — without these, "control" is a lie**

- Thread list with **real** state, including a count of threads blocked on you
- Read the transcript, newest first
- Send a prompt / steer a running thread
- **Approve, reject, or modify a pending tool call**
- Cancel the current turn

**Tier 2 — the difference between coping and working**

- Start a thread from a saved template (repo + agent mode + opening prompt)
- Switch agent mode on a thread
- Budget guard: warn, then auto-cancel, past a per-thread dollar cap
- **Offline draft queue** — compose while disconnected, deliver in order, once,
  when a link returns

**Tier 3 — ambient**

- Complication variants: threads running · **threads awaiting you** · today's spend
- Crown-scrollable overview of everything at once
- Handoff to the laptop via `NSUserActivity`

### Input

Dictation needs network, so it cannot be the only method. In order of expected
use: **saved phrases** synced from the phone (the real speed win), Scribble,
the watch keyboard, then dictation.

## The approval screen is a security surface

The watch can now approve shell commands. Judging a command you cannot fully
read is worse than not having the feature.

- Monospace, scrollable, **never truncated without saying so**
- Destructive patterns (`rm -rf`, force push, `DROP TABLE`, credential paths)
  flagged before you can approve
- When the input does not fit, the default action is **Defer**, not Approve
- No auto-approval, ever. No "approve all".
- Approvals require the phone link. In fallback mode the button is absent, not
  disabled-looking-clickable.

## Alerts

**v1 — no server.** The phone polls in the background and posts a local
notification, which the system mirrors to your watch. Latency is minutes; iOS
background refresh is opportunistic. Good enough for "it finished", too slow
for "it is blocked on you".

**v2 — direct APNs from the plugin.** You have a paid developer account, so
APNs is available. The plugin in the orb can hold an APNs `.p8` key and POST a
push itself the moment `state` becomes `awaiting-approval`, with no separate
server anywhere. *To verify:* APNs requires HTTP/2, and whether the plugin
runtime's `fetch` speaks HTTP/2 is unconfirmed. If not, a ~50-line Worker
relays it.

Notification actions (`Approve`, `Reject`, `Continue`) act without opening the
app — the shortest possible loop and the expected common case.

## Architecture

```diagram
        ┌────────────────┐        ┌──────────────────────────┐
        │ Watch app      │        │ iPhone app               │
        │  SwiftUI views │◀──WC──▶│  broker + Keychain       │
        │  offline queue │        │  poller + notifications  │
        └───────┬────────┘        └─────────┬────────────────┘
                │                           │
                └────── AmpKit ─────────────┘
                   shared, platform-neutral:
                   models · client · state machine · formatting
                        │
        ┌───────────────┴───────────────┐
        ▼                               ▼
  External API (read)            bridge plugin in orb
                                 state · approvals · cancel · create
```

`AmpKit` stays the centre of gravity: it builds and tests on Linux, so the
interesting logic — the approval state machine, the offline queue's
exactly-once delivery, ranking, formatting — is verified in an orb without a
Mac or a simulator. Views stay thin on purpose.

## Milestones

Each ends with CI screenshots as its reviewable artifact.

| # | Scope | Done when |
| --- | --- | --- |
| **M0** ✅ | Fixture UI, CI builds + screenshots on a watchOS simulator | Done |
| **M1** | **Connectivity truth** | In your actual classroom: does the watch reach the phone next door, over what, and how fast. Everything downstream assumes this |
| **M2** | Phone broker + real reads | Watch shows your real threads, with credentials only on the phone |
| **M3** | Bridge plugin + **approvals** | Approve a real tool call from the watch; the pending-handler ceiling is **measured** and documented; timeout auto-rejects with a stated reason |
| **M4** | Tier 2 + offline queue | Three prompts written in airplane mode arrive in order, exactly once |
| **M5** | Alerts | Local-notification path working; APNs-from-plugin spike resolved either way |
| **M6** | Battery + polish | Measured drain across a real school day; VoiceOver; always-on rendering |

M1 is first because it is the only one that can invalidate the rest.

## What "correct" means

The dangerous bugs here are **lies**, not crashes:

- An approval that says it went through when the handler had already timed out
- A queued prompt delivered twice after a reconnect
- The approval button visible while the phone link is down
- A truncated command presented as if it were complete
- A stale `idle` shown while the thread is actually blocked on you

Each gets a test in `AmpKit`, where it runs without a simulator.

## Open questions for you

1. **Watch model?** Series 5 and SE are 2.4 GHz only, which matters for school
   Wi-Fi. Cellular would remove the dependence on the phone entirely.
2. **School Wi-Fi: does it have a login page?** Apple Watch cannot join captive
   networks at all. If it does, the watch reaches the phone by Bluetooth only —
   which is likely fine at one room's distance, but changes M1's result. Your
   laptop's hotspot is a good fallback since it is not captive.
3. **Why the watch and not the laptop you always have?** I am assuming
   discretion — that a wrist glance is acceptable in a room where a laptop is
   not. If the real reason is different, the whole priority order changes.

## Non-goals

- Reading or writing code, viewing diffs. The laptop is always with you.
- Browsing history or search. That is the phone's job.
- Holding workspace-wide credentials on the watch in normal operation.
