# AmpWatch — design

## Thesis

A watch is not a small phone. It is an **ambient awareness device with an
interrupt channel**, and it is worn for the seconds when you are not at a
computer. So AmpWatch does exactly one job:

> Tell me whether my agents still need me, and let me say one sentence back.

Everything that takes longer than a glance is handed off to the phone or the
web. The app never tries to be a place where you read code, review a diff, or
approve a plan.

## Who it is for

Someone who runs several Amp threads in orbs, walks away, and wants to know —
without pulling out a phone — whether anything finished, stalled, or is
quietly burning money. Amp already has official iOS and macOS apps with
notifications; the watch wins only on **raise-to-wake, complication, and
haptics**, and loses on everything involving reading or typing. The design
leans entirely on the first three.

## Interaction budget

Every screen has a time budget. If a design cannot meet it, the design is
wrong, not the budget.

| Action | Budget | Surface |
| --- | --- | --- |
| Is anything different? | 2 s | Watch face complication |
| What changed? | 5 s | Thread list |
| What did it say? | 8 s | Thread transcript, newest first |
| Say one sentence back | 10 s | Dictation + preset chips |
| Anything longer | — | Hand off to iPhone / web |

## The feature that makes it worth wearing

Not the thread list — the **stall detector**.

The External API exposes no agent run state, only `updatedAt`. But a client
that polls repeatedly can see something a single request cannot: whether
`updatedAt` is still advancing. From a sequence of observations you can derive
the transition that actually matters —

> this thread was moving, and now it has stopped.

That is the notification a user wants ("amp finished", "amp is stuck"), and it
needs no push server, no Apple Developer account, and no cooperation from Amp.

```diagram
poll t0   updatedAt = 09:40:12   ─┐
poll t1   updatedAt = 09:43:55    ├─ advancing → moving
poll t2   updatedAt = 09:47:01   ─┘
poll t3   updatedAt = 09:47:01   ─┐
poll t4   updatedAt = 09:47:01   ─┴─ unchanged across 2 polls → SETTLED
                                     └─▶ local notification, once
```

### What this costs honestly

- watchOS background refresh is **opportunistic**, not scheduled. Realistic
  latency is minutes to tens of minutes, and the budget is granted mainly to
  apps with a complication on the *active* watch face. The complication is
  therefore not decoration; it is the mechanism that buys the refresh budget.
- The detector must fire **once** per settle, not once per poll. That is the
  single most likely bug in the whole app and it gets a test.
- A thread that settles and then resumes must be able to settle again.

## Screens

### 0. Complication — the primary surface

Most sessions begin and end here. Variants:

- **Activity**: count of threads currently moving, e.g. `3 ●`.
- **Last settled**: the title of the thread that most recently stopped.
- **Spend**: today's usage from `GET /workspace/analytics/daily-usage`, a number
  that visibly moves through the day.

### 1. Now — the root list

Not "all threads". Ranked by *what changed*, moving first, then most recently
settled, then quiet. Capped at ~10 rows, with an "open on iPhone" escape at the
bottom.

Each row is a dot, a serif title, and a repo plus elapsed time. The dot is
filled for moving and hollow otherwise, so state survives greyscale always-on
rendering and colour-blind vision rather than relying on the ember tint alone.

Activity **rolls up from subthreads**: a parent whose child thread is moving
reads as moving, because that is what is true for the user.

### 2. Thread — newest message first

A deliberate inversion of the web app. You raise your wrist to see *what just
happened*, not to read a conversation from the top.

Aggressive collapsing, because the glance is the product:

- Tool calls collapse to one line — `ran 3 tools`.
- Code blocks collapse to a label — ` ```swift · 24 lines `. Code is
  unreadable at 40mm and pushes the answer off-screen.
- Only text blocks render.

### 3. Reply — dictation first

A large mic target, plus preset chips for the three things anyone actually says
from a wrist: **Continue**, **Stop**, **Explain**. Scribble as fallback.

The UI says "queued", never "sent": the write path is fire-and-forget (see
below), so claiming delivery would be a lie.

### 4. Cost — secondary

Thread spend with a per-model breakdown, reachable from a thread. Demoted from
top level: spend is an anxiety, not an interrupt.

### 5. Handoff

`NSUserActivity` carrying the `ampcode.com/threads/T-…` URL, so the decision
"I need to actually deal with this" costs one gesture. The watch's real job is
to help you decide *whether* to engage; handoff is how it gets out of the way.

### 6. Notification

Local notification on settle, with actions that fire the webhook **without
opening the app**: `Continue`, `Mute this thread`. Replying from the
notification is the shortest possible loop and should be the common case.

## Architecture

```diagram
┌────────────────┐   ┌──────────────────┐
│ Complication   │   │ Background       │
│ (buys refresh  │   │ refresh task     │
│  budget)       │   └────────┬─────────┘
└───────┬────────┘            │
        └──────────┬──────────┘
                   ▼
         ┌───────────────────────┐
         │ ThreadStore           │  observations + settle transitions
         │ (small local file)    │  ← the only stateful piece
         └───┬───────────────┬───┘
             │               │
   AmpClient │               │ AmpPromptSink
   (read)    ▼               ▼ (write)
   ┌──────────────┐   ┌────────────────┐
   │ External API │   │ plugin webhook │
   │ ampcode.com  │   │ in an orb      │
   └──────────────┘   └────────────────┘
```

`ThreadStore` is the only stateful component: a small persisted list of
`(threadID, lastSeenUpdatedAt, lastNotifiedSettleAt)`. Not SwiftData — under a
hundred rows does not justify a migration story on watchOS.

Everything else derives. Activity, settle transitions, ranking and roll-up are
all pure functions of observations plus a clock, which is why they live in
`AmpKit` and are tested without a simulator.

## Constraints that shaped the design

These are verified against the public API, not assumed.

| Constraint | Consequence |
| --- | --- |
| External API is **read-only** for threads | Writes go through an Amp plugin webhook |
| Webhook handler returns `void` | No reply is ever visible to the watch; UI says "queued" |
| Webhook: 10 events/min, burst 10 | Presets and dictation, not a chat client |
| Archiving the webhook's owning thread → 404 | Onboarding must explain keeping that thread alive |
| **No agent run state** over HTTP | Stall detection is derived from `updatedAt` deltas |
| Message payloads explicitly unstable | Decode to `JSONValue`, extract defensively |
| `title`/`repositories` need `threads.contents:view` | Both optional throughout |
| `/threads` sorts by **first sync time**, not `updatedAt` | Must fetch a window and re-sort client-side; a long-lived thread that becomes active again can fall outside the window. Needs a window size chosen deliberately and revisited. |
| No APNs without a paid account | v1 uses local notifications from background refresh |

## The biggest open risk: credentials

The External API authenticates **machine-to-machine OAuth clients** created at
`ampcode.com/workspace/applications`. "Sign in with Amp" for third-party apps is
documented as not generally available. That produces three problems:

1. The credential is **workspace-scoped**. It can read every thread in the
   workspace, not just yours. Filtering to `userID` client-side narrows the
   *display*, not the *power* of the token.
2. It is a **long-lived secret**, and putting one on a watch is bad practice.
3. Typing or dictating it on a watch is not a plan.

Three ways out, in increasing order of effort:

- **A — companion paste (v1).** A minimal iOS app takes the credentials and
  hands them to the watch over WatchConnectivity, into the Keychain. Acceptable
  for a personal workspace. Loudly unacceptable for a shared one, and not
  shippable to the App Store.
- **B — plugin serves reads.** Rejected: webhooks return no body, and an orb
  portal authenticates against a browser session, which a watch does not have.
- **C — a user-hosted broker.** ~100 lines on a free Cloudflare Worker holding
  the M2M secret, doing the token exchange, filtering to one user, and issuing
  the watch a narrow device token. This is the correct answer and also removes
  the dependency on an orb staying alive for writes.

**Plan: ship A, document its blast radius in bold, build C before anyone in a
shared workspace uses this.**

## Distribution reality

Worth stating before anyone is disappointed: with a free Apple ID a
self-built watch app expires after **7 days** and must be re-signed. A paid
account ($99/yr) gets a year. The App Store is effectively blocked while
option A is the auth story. Realistic audience for v1 is "people who will run
`xcodegen && xcodebuild` themselves".

## Milestones

Each milestone ends with CI screenshots as its acceptance artifact, so progress
is reviewable without a Mac.

| # | Scope | Done when |
| --- | --- | --- |
| **M0** ✅ | Fixture-rendered UI, CI builds + screenshots on a watchOS simulator | Six screens captured as artifacts from a green run |
| **M1** | Live read path; onboarding via iOS companion; real thread list | Real threads appear on a simulator with a real token; `threads.contents:view` absent still renders |
| **M2** | `ThreadStore`, stall detection, complication, background refresh, local notifications | A thread that goes quiet notifies **exactly once**; resuming and settling again notifies again |
| **M3** | Write path: bridge plugin, dictation, notification actions | A dictated prompt appears in a real thread; a 429 surfaces as a retry hint, not a lie |
| **M4** | Handoff, cost, VoiceOver, always-on rendering | Screenshots pass in greyscale/always-on; every element has a label |
| **M5** | APNs push | Blocked on a paid account — explicitly out of scope until then |

M0 exists specifically so the verification loop is proven *before* features are
built on top of it. Nothing after M0 is worth starting if an agent cannot see
what it changed.

## What "correct" means

The interesting bugs here are not crashes, they are **lies**: the app claiming
something happened that did not. The tests target those:

- A settle fires once, not once per poll, and can fire again after a resume.
- A thread with a future `updatedAt` (clock skew) is not reported as stalled.
- A tool-only message renders as "tool activity", not as an empty bubble.
- A queued prompt says "queued", and a 429 does not render as success.
- Unknown fields in a message payload do not drop the message.

## Non-goals

- Reading or editing code, viewing diffs, approving tool calls.
- A full thread list, search, or history browsing — that is the phone's job.
- Starting new threads from the watch. Choosing a project and repo is a
  keyboard task, and the API cannot create threads anyway.
- Anything requiring the watch to be a trusted holder of workspace secrets
  beyond what option A already concedes.
