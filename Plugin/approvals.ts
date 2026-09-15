/**
 * Approvals from the wrist: which tool calls get held, how a call is shown,
 * and the queue a `tool.call` handler waits on. Pure; `bun test` covers it.
 *
 * A thread is *armed* by the watch (`arm` command). Off by default, so the
 * plugin never holds a call in a thread nobody asked it to watch — including
 * the threads that build this repo.
 */

export const ARM_LEVELS = ['off', 'risky', 'all'] as const
export type ArmLevel = (typeof ARM_LEVELS)[number]

/** Tools that run commands. Everything else (edits, reads, searches) is never held. */
export const GATED_TOOLS = new Set(['shell_command', 'Bash', 'bash'])

/**
 * Substrings that make a shell command worth a look before it runs. Kept in
 * step with `PendingApproval.destructivePatterns` in AmpKit — a test reads
 * the Swift file and compares — so the watch warns about exactly the calls
 * the bridge holds.
 */
export const DESTRUCTIVE_PATTERNS: readonly string[] = [
	'rm -rf',
	'rm -fr',
	'push --force',
	'push -f',
	'reset --hard',
	'drop table',
	'drop database',
	'truncate table',
	'mkfs',
	'dd if=',
	'::delete',
	'--no-verify',
	'chmod 777',
	'curl',
	'id_rsa',
	'.env',
	'credentials',
]

/** The longest command text a push carries; APNs allows 4 KB in total. */
export const MAX_INPUT_LENGTH = 1500

export interface RenderedInput {
	text: string
	complete: boolean
}

/** The part of a tool's input a person needs to see: the command itself, or the JSON. */
export function renderInput(tool: string, input: Record<string, unknown>): RenderedInput {
	let text: string
	if (GATED_TOOLS.has(tool) && typeof input.command === 'string') {
		const workdir = typeof input.workdir === 'string' && input.workdir.length > 0 ? `${input.workdir} $ ` : ''
		text = workdir + input.command
	} else {
		text = JSON.stringify(input, null, 1) ?? ''
	}
	text = text.trim()
	if (text.length <= MAX_INPUT_LENGTH) return { text, complete: true }
	return { text: text.slice(0, MAX_INPUT_LENGTH), complete: false }
}

/** Whether this call is held for the watch at the thread's arm level. */
export function needsWatchApproval(level: ArmLevel, tool: string, input: Record<string, unknown>): boolean {
	if (level === 'off' || !GATED_TOOLS.has(tool)) return false
	if (level === 'all') return true
	const haystack = renderInput(tool, input).text.toLowerCase()
	return DESTRUCTIVE_PATTERNS.some((pattern) => haystack.includes(pattern))
}

export interface ApprovalRequest {
	/** The tool use ID; unique within the thread and what the watch sends back. */
	id: string
	threadID: string
	toolName: string
	input: string
	inputIsComplete: boolean
	/** Unix milliseconds. */
	requestedAt: number
}

export const DECISIONS = ['approve', 'reject', 'defer'] as const
export type Decision = (typeof DECISIONS)[number]
export type Outcome = 'approve' | 'reject' | 'timeout'

interface Waiter {
	request: ApprovalRequest
	resolve: (outcome: Outcome) => void
	timer: ReturnType<typeof setTimeout>
}

/**
 * Calls waiting on a decision. `wait` resolves when `decide` names the call
 * or the timeout elapses. `defer` is acknowledged but changes nothing: the
 * watch saw it and chose not to answer, and the call keeps waiting.
 */
export class ApprovalQueue {
	private readonly waiters = new Map<string, Waiter>()

	wait(request: ApprovalRequest, timeoutMs: number): Promise<Outcome> {
		this.cancel(request.id)
		return new Promise((resolve) => {
			const timer = setTimeout(() => {
				this.waiters.delete(request.id)
				resolve('timeout')
			}, timeoutMs)
			this.waiters.set(request.id, { request, resolve, timer })
		})
	}

	/**
	 * Returns false when no call with that ID is waiting, or when the waiting
	 * call belongs to a different thread than the decision names: the watch
	 * decided about something else, and a stray approve must not land here.
	 */
	decide(id: string, decision: Decision, threadID?: string): boolean {
		const waiter = this.waiters.get(id)
		if (!waiter) return false
		if (threadID !== undefined && waiter.request.threadID !== threadID) return false
		if (decision === 'defer') return true
		clearTimeout(waiter.timer)
		this.waiters.delete(id)
		waiter.resolve(decision)
		return true
	}

	/** Resolves a waiting call as a timeout, e.g. when the thread is cancelled. */
	cancel(id: string): void {
		const waiter = this.waiters.get(id)
		if (!waiter) return
		clearTimeout(waiter.timer)
		this.waiters.delete(id)
		waiter.resolve('timeout')
	}

	pending(): ApprovalRequest[] {
		return [...this.waiters.values()].map((waiter) => waiter.request)
	}
}
