/**
 * AmpWatch bridge: the write path from the watch into Amp, and the push path
 * from Amp to the watch.
 *
 * The External API is read-only for threads, so the watch cannot prompt,
 * cancel or create through ampcode.com directly. This plugin runs in every
 * orb thread of the project. Each instance registers the same durable webhook
 * key; Amp hands every event to one registrant (the first, measured in
 * `docs/DESIGN.md`), so all instances carry the same handler and it does not
 * matter which one Amp picks. The watch POSTs commands to that URL:
 *
 *   { "type": "prompt" | "steer", "threadID": "T-…", "prompt": "…" }
 *   { "type": "cancel", "threadID": "T-…" }
 *   { "type": "create", "prompt": "…", "mode"?: "low"|"medium"|"high"|"ultra" }
 *   { "type": "register", "deviceToken": "<64 hex>", "environment"?: "sandbox"|"production" }
 *   { "type": "arm", "threadID": "T-…", "level": "off"|"risky"|"all" }
 *   { "type": "decide", "threadID": "T-…", "approvalID": "toolu_…", "decision": "approve"|"reject"|"defer" }
 *
 * and every instance POSTs its own thread's turn outcomes to the same URL:
 *
 *   { "type": "announce", "threadID": "T-…", "outcome": "done"|"error"|"cancelled"|"awaiting-approval", … }
 *
 * The receiving instance turns announcements into APNs pushes for every
 * registered watch (`apns.ts`). Registrations live in that instance's memory;
 * the watch re-registers on every launch, which is what keeps this simple.
 *
 * Approvals need the *thread's own* instance, because only it sits in that
 * thread's `tool.call` handler. Each instance therefore also registers a
 * per-thread key (`approve-<threadID>`) and tells the shared receiver its URL
 * with a `link` command at the start of every turn; the receiver forwards
 * `arm` and `decide` there. Threads are unarmed by default: the bridge holds
 * nothing until the watch arms that thread. See `approvals.ts` for what is
 * held at each level.
 *
 * The *hub* — the one orb with a `.amp/ampwatch-hub` marker file, gitignored —
 * additionally writes the capability URL to `.amp/ampwatch-hub.url` (mode 600)
 * so the owner can copy it into the watch once. The URL is a credential: it is
 * never logged and never posted into a thread.
 *
 * Limits that shape the watch UI: a burst of 10 events, refilling at 10 per
 * minute, shared between watch commands and announcements; the handler
 * returns no body, so the watch learns only that Amp accepted the event;
 * delivery is at-least-once, hence `SeenEvents`.
 */
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import type { PluginAPI, ThreadID, ThreadMessage } from '@ampcode/plugin'
import {
	buildProviderToken,
	buildRequest,
	readCredentials,
	tokenIsFresh,
	type ApnsCredentials,
	type ProviderToken,
	type PushEvent,
} from './apns'
import { ApprovalQueue, needsWatchApproval, renderInput, type ArmLevel } from './approvals'
import { parseCommand, SeenEvents, type AnnounceOutcome, type WatchCommand } from './commands'

export const HUB_MARKER = '.amp/ampwatch-hub'
export const HUB_URL_FILE = '.amp/ampwatch-hub.url'
export const WEBHOOK_KEY = 'amp-watch'

/**
 * How long a held call waits for the watch. Amp itself lets a `tool.call`
 * handler stay pending for at least 20 minutes (measured, see
 * `docs/DESIGN.md` Unknown 2), so this is a product choice: long enough to
 * finish a class exercise and glance at the wrist, short enough that a thread
 * nobody is watching does not sit idle for an hour. The watch's
 * `Outbox.decisionTTL` must equal this.
 */
export const APPROVAL_TIMEOUT_MS = 10 * 60 * 1000

/** Where pushes go. Keyed by device token, so a re-register is idempotent. */
type Registrations = Map<string, { environment: 'sandbox' | 'production' }>

/** What the shared receiver knows: who to push, and where each thread takes decisions. */
interface Receiver {
	registrations: Registrations
	approvalLinks: Map<string, string>
	pusher: Pusher
}

/** What this instance knows about the threads it sits in. */
interface Guard {
	levels: Map<string, ArmLevel>
	queue: ApprovalQueue
	/** Per-thread webhook URLs, created on first use. */
	links: Map<string, Promise<string>>
}

export default async function (amp: PluginAPI) {
	const root = amp.system.workspaceRoot ? amp.helpers.filePathFromURI(amp.system.workspaceRoot) : null
	const isHub = root !== null && existsSync(join(root, HUB_MARKER))

	const seen = new SeenEvents()
	const receiver: Receiver = { registrations: new Map(), approvalLinks: new Map(), pusher: new Pusher(amp) }
	const guard: Guard = { levels: new Map(), queue: new ApprovalQueue(), links: new Map() }

	const { url } = await amp.createWebhook({
		key: WEBHOOK_KEY,
		handler: async (event, ctx) => {
			if (!seen.markSeen(event.id)) {
				ctx.logger.log(`amp-watch: repeat delivery of ${event.id} ignored`)
				return
			}
			const parsed = parseCommand(event.body)
			if (!parsed.ok) {
				// Do not throw: at-least-once delivery would retry a malformed
				// event forever.
				ctx.logger.log(`amp-watch: discarding event ${event.id}: ${parsed.reason}`)
				return
			}
			await apply(amp, parsed.command, receiver)
			ctx.logger.log(`amp-watch: applied ${describe(parsed.command)}`)
		},
	})

	/** The URL the shared receiver forwards this thread's `arm` and `decide` to. */
	function approvalURL(threadID: string): Promise<string> {
		let link = guard.links.get(threadID)
		if (!link) {
			link = amp
				.createWebhook({
					key: `approve-${threadID}`,
					handler: async (event, ctx) => {
						if (!seen.markSeen(event.id)) return
						const parsed = parseCommand(event.body)
						if (!parsed.ok || (parsed.command.type !== 'arm' && parsed.command.type !== 'decide')) {
							ctx.logger.log(`amp-watch: approval webhook discarding event ${event.id}`)
							return
						}
						const command = parsed.command
						if (command.type === 'arm') {
							guard.levels.set(command.threadID, command.level)
							ctx.logger.log(`amp-watch: ${describe(command)}`)
							return
						}
						const known = guard.queue.decide(command.approvalID, command.decision)
						ctx.logger.log(`amp-watch: ${describe(command)}${known ? '' : ' (nothing waiting)'}`)
					},
				})
				.then((registration) => registration.url)
			guard.links.set(threadID, link)
		}
		return link
	}

	async function post(body: Record<string, unknown>): Promise<void> {
		const response = await fetch(url, {
			method: 'POST',
			headers: { 'content-type': 'application/json' },
			body: JSON.stringify(body),
		})
		if (!response.ok) amp.logger.log(`amp-watch: ${String(body.type)} rejected with HTTP ${response.status}`)
	}

	// Tell the receiver where this thread takes decisions: now, and at every
	// turn rather than once, because the receiving instance keeps links in
	// memory and may have restarted.
	async function link(threadID: string): Promise<void> {
		await post({ type: 'link', threadID, approvalURL: await approvalURL(threadID) })
	}
	const linked = new Set<string>()
	amp.activeThread.subscribe((thread) => {
		if (!thread || linked.has(thread.id)) return
		linked.add(thread.id)
		void link(thread.id)
	})
	amp.on('agent.start', async (event) => {
		await link(event.thread.id)
		return {}
	})

	amp.on('tool.call', async (event) => {
		const level = guard.levels.get(event.thread.id) ?? 'off'
		if (!needsWatchApproval(level, event.tool, event.input)) return { action: 'allow' }

		const rendered = renderInput(event.tool, event.input)
		const request = {
			id: event.toolUseID,
			threadID: event.thread.id,
			toolName: event.tool,
			input: rendered.text,
			inputIsComplete: rendered.complete,
			requestedAt: Date.now(),
		}
		const decision = guard.queue.wait(request, APPROVAL_TIMEOUT_MS)
		await post({
			type: 'announce',
			threadID: event.thread.id,
			outcome: 'awaiting-approval',
			title: await amp.threads.get(event.thread.id).title.get(),
			summary: null,
			approval: { id: request.id, toolName: request.toolName, input: request.input, inputIsComplete: request.inputIsComplete },
		})
		const outcome = await decision
		amp.logger.log(`amp-watch: ${event.tool} ${request.id} ${outcome}`)
		switch (outcome) {
			case 'approve':
				return { action: 'allow' }
			case 'reject':
				return { action: 'reject-and-continue', message: 'Rejected from the watch. Do not retry it; explain what you would have done and wait.' }
			case 'timeout':
				return {
					action: 'reject-and-continue',
					message: `Nobody approved this from the watch within ${APPROVAL_TIMEOUT_MS / 60000} minutes. Do not retry it; say what is blocked and wait.`,
				}
		}
	})

	if (isHub && root) {
		writeFileSync(join(root, HUB_URL_FILE), url + '\n', { mode: 0o600 })
		amp.logger.log(`amp-watch: hub ready; capability URL written to ${HUB_URL_FILE}`)
	} else {
		amp.logger.log('amp-watch: registered (not the hub; no URL file written)')
	}

	// Report this thread's turn outcomes. Goes through the webhook rather than
	// straight to `pusher` because the registrations live with whichever
	// instance Amp delivers to, and that may not be this one.
	amp.on('agent.end', async (event) => {
		// A cancelled turn takes its held calls with it.
		for (const pending of guard.queue.pending()) {
			if (pending.threadID === event.thread.id) guard.queue.cancel(pending.id)
		}
		const outcome: AnnounceOutcome = event.status
		await post({
			type: 'announce',
			threadID: event.thread.id,
			outcome,
			title: await amp.threads.get(event.thread.id).title.get(),
			summary: lastAssistantLine(event.messages),
		})
	})
}

async function apply(amp: PluginAPI, command: WatchCommand, receiver: Receiver): Promise<void> {
	const { registrations, approvalLinks, pusher } = receiver
	switch (command.type) {
		case 'prompt':
			await amp.threads
				.get(command.threadID as ThreadID)
				.appendUserMessage({ type: 'user-message', content: command.prompt }, { steer: command.steer })
			return
		case 'cancel':
			await amp.threads.get(command.threadID as ThreadID).cancel()
			return
		case 'create': {
			const thread = await amp.getBuiltinAgent(command.mode).createThread({ executor: 'orb' })
			await thread.append([{ type: 'user-message', content: command.prompt }])
			return
		}
		case 'register':
			registrations.set(command.deviceToken, { environment: command.environment })
			return
		case 'announce': {
			const event = pushEvent(command)
			if (!event) return
			for (const [deviceToken, registration] of registrations) {
				const outcome = await pusher.send(deviceToken, registration.environment, event)
				if (outcome === 'gone') registrations.delete(deviceToken)
			}
			return
		}
		case 'link':
			approvalLinks.set(command.threadID, command.approvalURL)
			return
		case 'arm':
		case 'decide': {
			const target = approvalLinks.get(command.threadID)
			if (!target) {
				amp.logger.log(`amp-watch: no approval link for ${command.threadID}; has it started a turn since the receiver restarted?`)
				return
			}
			const response = await fetch(target, {
				method: 'POST',
				headers: { 'content-type': 'application/json' },
				body: JSON.stringify(command),
			})
			if (!response.ok) amp.logger.log(`amp-watch: forwarding ${command.type} failed with HTTP ${response.status}`)
			return
		}
	}
}

function pushEvent(command: Extract<WatchCommand, { type: 'announce' }>): PushEvent | null {
	switch (command.outcome) {
		case 'done':
			return { kind: 'thread-done', threadID: command.threadID, title: command.title, summary: command.summary }
		case 'error':
			return { kind: 'thread-error', threadID: command.threadID, title: command.title, summary: command.summary }
		case 'cancelled':
			// The watch (or the user at a keyboard) asked for this; nothing to say.
			return null
		case 'awaiting-approval':
			if (!command.approval) return null
			return {
				kind: 'approval',
				threadID: command.threadID,
				title: command.title,
				approvalID: command.approval.id,
				toolName: command.approval.toolName,
				summary: command.approval.input,
				inputIsComplete: command.approval.inputIsComplete,
				requestedAt: Date.now(),
			}
	}
}

/** The first line of the last assistant text block, for the notification body. */
export function lastAssistantLine(messages: ThreadMessage[]): string | null {
	for (let index = messages.length - 1; index >= 0; index--) {
		const message = messages[index]
		if (message.role !== 'assistant') continue
		for (let block = message.content.length - 1; block >= 0; block--) {
			const content = message.content[block]
			if (content.type !== 'text') continue
			const line = content.text
				.split('\n')
				.map((part) => part.trim())
				.find((part) => part.length > 0)
			if (line) return line
		}
	}
	return null
}

/**
 * Sends pushes through the orb's `curl --http2`. Credentials are read from the
 * environment on first use and the provider token is cached for 50 minutes.
 */
export class Pusher {
	private credentials: ApnsCredentials | null | undefined
	private token: ProviderToken | null = null

	constructor(private readonly amp: PluginAPI) {}

	async send(deviceToken: string, environment: 'sandbox' | 'production', event: PushEvent): Promise<'sent' | 'failed' | 'gone' | 'unconfigured'> {
		const credentials = this.loadCredentials()
		if (!credentials) return 'unconfigured'
		if (!this.token || !tokenIsFresh(this.token)) this.token = await buildProviderToken(credentials)

		const request = buildRequest({
			credentials: { ...credentials, environment },
			providerToken: this.token,
			deviceToken,
			event,
		})

		// A curl config file keeps the bearer token out of argv and out of any
		// shell quoting; JWTs and URLs contain nothing that needs escaping.
		const dir = mkdtempSync(join(tmpdir(), 'amp-watch-push-'))
		try {
			const bodyPath = join(dir, 'body.json')
			const configPath = join(dir, 'curl.cfg')
			const responsePath = join(dir, 'response.json')
			writeFileSync(bodyPath, request.body, { mode: 0o600 })
			const config = [
				`url = "${request.url}"`,
				...Object.entries(request.headers).map(([name, value]) => `header = "${name}: ${value}"`),
				`data-binary = "@${bodyPath}"`,
				`output = "${responsePath}"`,
				'write-out = "%{http_code}"',
			].join('\n')
			writeFileSync(configPath, config + '\n', { mode: 0o600 })

			const result = await this.amp.$`curl --http2 --silent --show-error --max-time 20 --config ${configPath}`
			const status = result.stdout.trim()
			if (status === '200') return 'sent'
			if (status === '410') {
				this.amp.logger.log(`amp-watch: device token no longer valid; dropped`)
				return 'gone'
			}
			// Log status and Apple's reason only; neither contains the token.
			this.amp.logger.log(`amp-watch: push failed: HTTP ${status || 'none'} ${apnsReason(responsePath) ?? result.stderr.trim()}`.trim())
			if (status === '403') this.token = null
			return 'failed'
		} finally {
			rmSync(dir, { recursive: true, force: true })
		}
	}

	private loadCredentials(): ApnsCredentials | null {
		if (this.credentials !== undefined) return this.credentials
		const result = readCredentials(process.env)
		if (result.ok) {
			this.credentials = result.credentials
		} else {
			this.credentials = null
			this.amp.logger.log(`amp-watch: pushes off; set ${result.missing.join(', ')} (see docs/PUSH.md)`)
		}
		return this.credentials
	}
}

/** APNs answers errors with `{"reason": "…"}`; anything else is not worth logging. */
function apnsReason(responsePath: string): string | null {
	try {
		const parsed = JSON.parse(readFileSync(responsePath, 'utf8')) as { reason?: unknown }
		return typeof parsed.reason === 'string' ? parsed.reason : null
	} catch {
		return null
	}
}

function describe(command: WatchCommand): string {
	switch (command.type) {
		case 'prompt':
			return `${command.steer ? 'steer' : 'prompt'} → ${command.threadID}`
		case 'cancel':
			return `cancel → ${command.threadID}`
		case 'create':
			return `create (${command.mode})`
		case 'register':
			return `register watch (${command.environment})`
		case 'announce':
			return `announce ${command.outcome}${command.approval ? ` ${command.approval.id}` : ''} ← ${command.threadID}`
		case 'link':
			return `link ← ${command.threadID}`
		case 'arm':
			return `arm ${command.level} → ${command.threadID}`
		case 'decide':
			return `decide ${command.decision} ${command.approvalID} → ${command.threadID}`
	}
}
