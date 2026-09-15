/**
 * The wire format between the watch and the bridge, and nothing else.
 *
 * Pure: no Amp API, no I/O. `bun test` covers it. The bridge in
 * `amp-watch-bridge.ts` only turns a parsed command into plugin calls.
 */
import { ARM_LEVELS, DECISIONS, type ArmLevel, type Decision } from './approvals'

export const MAX_PROMPT_LENGTH = 4000
export const AGENT_MODES = ['low', 'medium', 'high', 'ultra'] as const
export type AgentMode = (typeof AGENT_MODES)[number]

export const ANNOUNCE_OUTCOMES = ['done', 'error', 'cancelled', 'awaiting-approval'] as const
export type AnnounceOutcome = (typeof ANNOUNCE_OUTCOMES)[number]

/** A held tool call, as carried in an `awaiting-approval` announcement and in the push. */
export interface ApprovalSummary {
	id: string
	toolName: string
	input: string
	inputIsComplete: boolean
	/**
	 * Unix milliseconds when the thread's instance held the call. The watch
	 * counts the decision window from this, so the clock is the bridge's,
	 * not the receiver's and not the wrist's.
	 */
	requestedAt: number
}

export type WatchCommand =
	| { type: 'prompt'; threadID: string; prompt: string; steer: boolean }
	| { type: 'cancel'; threadID: string }
	| { type: 'create'; prompt: string; mode: AgentMode }
	/** The watch tells the hub where to send pushes. Sent on every launch. */
	| { type: 'register'; deviceToken: string; environment: 'sandbox' | 'production' }
	/**
	 * A thread's own plugin instance reports a turn outcome to the hub. Every
	 * project thread posts these to the shared URL; only the hub turns them
	 * into pushes. `summary` is the assistant's last line, already clipped.
	 */
	| {
			type: 'announce'
			threadID: string
			outcome: AnnounceOutcome
			title: string | null
			summary: string | null
			/** Present only with outcome `awaiting-approval`. */
			approval: ApprovalSummary | null
			/**
			 * Where the receiver forwards this thread's `arm` and `decide`.
			 * Carried on every announcement so a receiver that restarted
			 * learns the link again without a separate message. The URL is
			 * a credential; it only ever travels inside Amp.
			 */
			approvalURL: string | null
	  }
	/**
	 * The watch answers a held tool call. Forwarded to the thread's own
	 * webhook. `commandID` is the watch's idempotency key; the forwarded copy
	 * gets a fresh event ID, so it is what the thread's instance dedupes on.
	 */
	| { type: 'decide'; threadID: string; approvalID: string; decision: Decision; commandID: string | null }
	/** The watch chooses which of a thread's tool calls are held. Forwarded likewise. */
	| { type: 'arm'; threadID: string; level: ArmLevel; commandID: string | null }
	/** A thread's plugin instance tells the receiver where to forward `decide` and `arm`. */
	| { type: 'link'; threadID: string; approvalURL: string }

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
		case 'register': {
			const deviceToken = fields.deviceToken
			if (typeof deviceToken !== 'string' || !/^[0-9a-f]{64}$/i.test(deviceToken)) {
				return { ok: false, reason: 'deviceToken missing or malformed' }
			}
			const environment = fields.environment === 'production' ? 'production' : 'sandbox'
			return { ok: true, command: { type: 'register', deviceToken: deviceToken.toLowerCase(), environment } }
		}
		case 'announce': {
			const threadID = readThreadID(fields)
			if (!threadID.ok) return threadID
			const outcome = fields.outcome
			if (!(ANNOUNCE_OUTCOMES as readonly unknown[]).includes(outcome)) {
				return { ok: false, reason: `unknown outcome ${String(outcome)}` }
			}
			const approval = readApproval(fields.approval)
			if (outcome === 'awaiting-approval' && approval === null) {
				return { ok: false, reason: 'awaiting-approval needs an approval' }
			}
			return {
				ok: true,
				command: {
					type: 'announce',
					threadID: threadID.value,
					outcome: outcome as AnnounceOutcome,
					title: optionalText(fields.title),
					summary: optionalText(fields.summary),
					approval: outcome === 'awaiting-approval' ? approval : null,
					approvalURL: readApprovalURL(fields.approvalURL),
				},
			}
		}
		case 'decide': {
			const threadID = readThreadID(fields)
			if (!threadID.ok) return threadID
			const approvalID = fields.approvalID
			if (typeof approvalID !== 'string' || approvalID.trim().length === 0) {
				return { ok: false, reason: 'approvalID missing' }
			}
			const decision = fields.decision
			if (!(DECISIONS as readonly unknown[]).includes(decision)) {
				return { ok: false, reason: `unknown decision ${String(decision)}` }
			}
			return {
				ok: true,
				command: {
					type: 'decide',
					threadID: threadID.value,
					approvalID: approvalID.trim(),
					decision: decision as Decision,
					commandID: optionalText(fields.commandID),
				},
			}
		}
		case 'arm': {
			const threadID = readThreadID(fields)
			if (!threadID.ok) return threadID
			const level = fields.level
			if (!(ARM_LEVELS as readonly unknown[]).includes(level)) {
				return { ok: false, reason: `unknown arm level ${String(level)}` }
			}
			return {
				ok: true,
				command: { type: 'arm', threadID: threadID.value, level: level as ArmLevel, commandID: optionalText(fields.commandID) },
			}
		}
		case 'link': {
			const threadID = readThreadID(fields)
			if (!threadID.ok) return threadID
			const approvalURL = readApprovalURL(fields.approvalURL)
			if (approvalURL === null) return { ok: false, reason: 'approvalURL missing or not https' }
			return { ok: true, command: { type: 'link', threadID: threadID.value, approvalURL } }
		}
		default:
			return { ok: false, reason: `unknown command type ${String(type)}` }
	}
}

type Field = { ok: true; value: string } | { ok: false; reason: string }

function readApproval(value: unknown): ApprovalSummary | null {
	if (typeof value !== 'object' || value === null) return null
	const fields = value as Record<string, unknown>
	if (typeof fields.id !== 'string' || typeof fields.toolName !== 'string' || typeof fields.input !== 'string') return null
	// The sender always writes the flag. A missing one is not "complete"; it
	// is a body this code did not build, and guessing would let a cut command
	// reach the Approve button.
	if (typeof fields.inputIsComplete !== 'boolean') return null
	if (typeof fields.requestedAt !== 'number' || !Number.isFinite(fields.requestedAt) || fields.requestedAt <= 0) return null
	return {
		id: fields.id,
		toolName: fields.toolName,
		input: fields.input,
		inputIsComplete: fields.inputIsComplete,
		requestedAt: fields.requestedAt,
	}
}

function readApprovalURL(value: unknown): string | null {
	return typeof value === 'string' && value.startsWith('https://') ? value : null
}

function optionalText(value: unknown): string | null {
	if (typeof value !== 'string') return null
	const trimmed = value.trim()
	return trimmed.length === 0 ? null : trimmed.slice(0, MAX_PROMPT_LENGTH)
}

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
