/**
 * AmpWatch write bridge.
 *
 * The Amp External API is read-only for threads, so the watch cannot post a
 * prompt to ampcode.com directly. This plugin opens one durable webhook and
 * appends whatever the watch sends as a user message on the target thread.
 *
 * Load it in an orb thread you keep around:
 *
 *   amp plugins load Plugin/amp-watch-bridge.ts
 *
 * It replies with a capability URL. Treat that URL as a password — anyone
 * holding it can prompt your threads without signing in to Amp. Put it in the
 * watch Keychain and nowhere else. Archiving the owning thread pauses its orb
 * and the URL starts returning 404.
 *
 * Limits that shape the watch UI: the webhook accepts a burst of 10 events and
 * refills at 10 per minute, the handler returns no body (so the watch learns
 * only that Amp accepted the event, never what the agent replied), and delivery
 * is at-least-once — hence the Idempotency-Key the watch sends.
 */
import type { PluginAPI, ThreadID } from '@ampcode/plugin'

interface WatchPrompt {
	threadID: string
	prompt: string
}

function parsePrompt(body: unknown): WatchPrompt | null {
	if (typeof body !== 'object' || body === null) return null
	const { threadID, prompt } = body as Record<string, unknown>
	if (typeof threadID !== 'string' || !threadID.startsWith('T-')) return null
	if (typeof prompt !== 'string') return null
	const trimmed = prompt.trim()
	if (trimmed.length === 0 || trimmed.length > 4000) return null
	return { threadID, prompt: trimmed }
}

export default async function (amp: PluginAPI) {
	const { url } = await amp.createWebhook({
		key: 'amp-watch',
		handler: async (event) => {
			const parsed = parsePrompt(event.body)
			if (!parsed) {
				// Do not throw: a malformed event would otherwise be retried
				// forever by at-least-once delivery.
				amp.logger.log('amp-watch: discarding malformed event')
				return
			}

			await amp.threads.get(parsed.threadID as ThreadID).appendUserMessage(
				{ type: 'user-message', content: parsed.prompt },
				// Prefer the wrist prompt over queued work: the whole point is
				// to redirect an agent that is already running.
				{ steer: true },
			)
			amp.logger.log(`amp-watch: delivered a prompt to ${parsed.threadID}`)
		},
	})

	amp.logger.log(`amp-watch bridge ready. Capability URL issued (${url.length} chars).`)
}
