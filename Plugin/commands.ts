/**
 * The wire format between the watch and the bridge, and nothing else.
 *
 * Pure: no Amp API, no I/O. `bun test` covers it. The bridge in
 * `amp-watch-bridge.ts` only turns a parsed command into plugin calls.
 */

export const MAX_PROMPT_LENGTH = 4000
export const AGENT_MODES = ['low', 'medium', 'high', 'ultra'] as const
export type AgentMode = (typeof AGENT_MODES)[number]

export type WatchCommand =
	| { type: 'prompt'; threadID: string; prompt: string; steer: boolean }
	| { type: 'cancel'; threadID: string }
	| { type: 'create'; prompt: string; mode: AgentMode }

export type ParseResult = { ok: true; command: WatchCommand } | { ok: false; reason: string }

export function parseCommand(body: Uint8Array | string | unknown): ParseResult {
	let value: unknown = body
	if (body instanceof Uint8Array || typeof body === 'string') {
		const text = typeof body === 'string' ? body : new TextDecoder().decode(body)
		try {
			value = JSON.parse(text)
		} catch {
			return { ok: false, reason: 'body is not JSON' }
		}
	}
	if (typeof value !== 'object' || value === null || Array.isArray(value)) {
		return { ok: false, reason: 'body is not an object' }
	}
	const fields = value as Record<string, unknown>

	// The first watch build sent `{threadID, prompt}` with no type; keep
	// accepting it as a steering prompt.
	const type = fields.type === undefined ? 'steer' : fields.type
	switch (type) {
		case 'prompt':
		case 'steer': {
			const threadID = readThreadID(fields)
			if (!threadID.ok) return threadID
			const prompt = readPrompt(fields)
			if (!prompt.ok) return prompt
			return {
				ok: true,
				command: { type: 'prompt', threadID: threadID.value, prompt: prompt.value, steer: type === 'steer' },
			}
		}
		case 'cancel': {
			const threadID = readThreadID(fields)
			if (!threadID.ok) return threadID
			return { ok: true, command: { type: 'cancel', threadID: threadID.value } }
		}
		case 'create': {
			const prompt = readPrompt(fields)
			if (!prompt.ok) return prompt
			const mode = fields.mode === undefined ? 'medium' : fields.mode
			if (!(AGENT_MODES as readonly unknown[]).includes(mode)) {
				return { ok: false, reason: `unknown mode ${String(mode)}` }
			}
			return { ok: true, command: { type: 'create', prompt: prompt.value, mode: mode as AgentMode } }
		}
		default:
			return { ok: false, reason: `unknown command type ${String(type)}` }
	}
}

type Field = { ok: true; value: string } | { ok: false; reason: string }

function readThreadID(fields: Record<string, unknown>): Field {
	const threadID = fields.threadID
	if (typeof threadID !== 'string' || !/^T-[0-9a-f-]{36}$/i.test(threadID)) {
		return { ok: false, reason: 'threadID missing or malformed' }
	}
	return { ok: true, value: threadID }
}

function readPrompt(fields: Record<string, unknown>): Field {
	const prompt = fields.prompt
	if (typeof prompt !== 'string') return { ok: false, reason: 'prompt missing' }
	const trimmed = prompt.trim()
	if (trimmed.length === 0) return { ok: false, reason: 'prompt empty' }
	if (trimmed.length > MAX_PROMPT_LENGTH) return { ok: false, reason: 'prompt too long' }
	return { ok: true, value: trimmed }
}

/**
 * Remembers the last `capacity` event IDs. Webhook delivery is at-least-once,
 * so a retried event must not prompt a thread twice.
 */
export class SeenEvents {
	private readonly order: string[] = []
	private readonly ids = new Set<string>()

	constructor(private readonly capacity = 500) {}

	/** Returns true the first time an ID is seen, false on every repeat. */
	markSeen(id: string): boolean {
		if (this.ids.has(id)) return false
		this.ids.add(id)
		this.order.push(id)
		if (this.order.length > this.capacity) {
			const oldest = this.order.shift()
			if (oldest !== undefined) this.ids.delete(oldest)
		}
		return true
	}
}
