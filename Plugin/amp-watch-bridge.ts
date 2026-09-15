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
 *
 * and every instance POSTs its own thread's turn outcomes to the same URL:
 *
 *   { "type": "announce", "threadID": "T-…", "outcome": "done"|"error"|"cancelled"|"awaiting-approval", … }
 *
 * The receiving instance turns announcements into APNs pushes for every
 * registered watch (`apns.ts`). Registrations live in that instance's memory;
 * the watch re-registers on every launch, which is what keeps this simple.
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
import { parseCommand, SeenEvents, type AnnounceOutcome, type WatchCommand } from './commands'

export const HUB_MARKER = '.amp/ampwatch-hub'
export const HUB_URL_FILE = '.amp/ampwatch-hub.url'
export const WEBHOOK_KEY = 'amp-watch'

/** Where pushes go. Keyed by device token, so a re-register is idempotent. */
type Registrations = Map<string, { environment: 'sandbox' | 'production' }>

export default async function (amp: PluginAPI) {
	const root = amp.system.workspaceRoot ? amp.helpers.filePathFromURI(amp.system.workspaceRoot) : null
	const isHub = root !== null && existsSync(join(root, HUB_MARKER))

	const seen = new SeenEvents()
	const registrations: Registrations = new Map()
	const pusher = new Pusher(amp)

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
			await apply(amp, parsed.command, registrations, pusher)
			ctx.logger.log(`amp-watch: applied ${describe(parsed.command)}`)
		},
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
		const outcome: AnnounceOutcome = event.status
		const title = await amp.threads.get(event.thread.id).title.get()
		const announcement = {
			type: 'announce',
			threadID: event.thread.id,
			outcome,
			title,
			summary: lastAssistantLine(event.messages),
		}
		const response = await fetch(url, {
			method: 'POST',
			headers: { 'content-type': 'application/json' },
			body: JSON.stringify(announcement),
		})
		if (!response.ok) amp.logger.log(`amp-watch: announce rejected with HTTP ${response.status}`)
	})
}

async function apply(amp: PluginAPI, command: WatchCommand, registrations: Registrations, pusher: Pusher): Promise<void> {
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
			// Approvals carry their own push from the tool.call handler (M4).
			return null
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
			return `announce ${command.outcome} ← ${command.threadID}`
	}
}
