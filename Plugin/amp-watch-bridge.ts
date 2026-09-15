/**
 * AmpWatch bridge: the write path from the watch into Amp.
 *
 * The External API is read-only for threads, so the watch cannot prompt,
 * cancel or create through ampcode.com directly. This plugin runs in the
 * project's orb threads. Exactly one of them — the *hub* — owns a durable
 * webhook and applies the commands the watch POSTs to it:
 *
 *   { "type": "prompt" | "steer", "threadID": "T-…", "prompt": "…" }
 *   { "type": "cancel", "threadID": "T-…" }
 *   { "type": "create", "prompt": "…", "mode"?: "low"|"medium"|"high"|"ultra" }
 *
 * Which thread is the hub is decided by a marker file in that orb's
 * workspace, `.amp/ampwatch-hub` (gitignored). Every other thread loads the
 * plugin too — for the approval hooks in `approvals.ts` — but must not
 * register the webhook: project threads of one user share a registration per
 * key, and two owners would race for the same events.
 *
 * The webhook URL is a credential. It is written to the hub orb's
 * `.amp/ampwatch-hub.url` (also gitignored) so the owner can copy it into the
 * watch once; it is never logged and never posted into a thread.
 *
 * Limits that shape the watch UI: a burst of 10 events, refilling at 10 per
 * minute; the handler returns no body, so the watch learns only that Amp
 * accepted the event; delivery is at-least-once, hence `SeenEvents`.
 */
import { existsSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import type { PluginAPI, ThreadID } from '@ampcode/plugin'
import { parseCommand, SeenEvents, type WatchCommand } from './commands'

export const HUB_MARKER = '.amp/ampwatch-hub'
export const HUB_URL_FILE = '.amp/ampwatch-hub.url'
export const WEBHOOK_KEY = 'amp-watch'

export default async function (amp: PluginAPI) {
	const root = amp.system.workspaceRoot ? amp.helpers.filePathFromURI(amp.system.workspaceRoot) : null
	if (!root || !existsSync(join(root, HUB_MARKER))) {
		amp.logger.log(`amp-watch: not the hub (no ${HUB_MARKER}); webhook not registered`)
		return
	}

	const seen = new SeenEvents()
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
			await apply(amp, parsed.command)
			ctx.logger.log(`amp-watch: applied ${describe(parsed.command)}`)
		},
	})

	writeFileSync(join(root, HUB_URL_FILE), url + '\n', { mode: 0o600 })
	amp.logger.log(`amp-watch: hub ready; capability URL written to ${HUB_URL_FILE}`)
}

async function apply(amp: PluginAPI, command: WatchCommand): Promise<void> {
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
	}
}
