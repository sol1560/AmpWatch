import { describe, expect, test } from 'bun:test'
import { MAX_PROMPT_LENGTH, parseCommand, SeenEvents } from './commands'

const thread = 'T-01a0a325-7a11-73eb-a5a7-46c40b37076d'
const bytes = (value: unknown) => new TextEncoder().encode(JSON.stringify(value))

describe('parseCommand', () => {
	test('reads the exact request bytes the webhook delivers', () => {
		const result = parseCommand(bytes({ type: 'prompt', threadID: thread, prompt: ' run tests ' }))
		expect(result).toEqual({
			ok: true,
			command: { type: 'prompt', threadID: thread, prompt: 'run tests', steer: false },
		})
	})

	test('steer differs from prompt only in the steer flag', () => {
		const result = parseCommand({ type: 'steer', threadID: thread, prompt: 'stop' })
		expect(result.ok && result.command.type === 'prompt' && result.command.steer).toBe(true)
	})

	test('an untyped legacy body is a steering prompt', () => {
		const result = parseCommand({ threadID: thread, prompt: 'hi' })
		expect(result).toEqual({
			ok: true,
			command: { type: 'prompt', threadID: thread, prompt: 'hi', steer: true },
		})
	})

	test('cancel needs only a thread', () => {
		expect(parseCommand({ type: 'cancel', threadID: thread })).toEqual({
			ok: true,
			command: { type: 'cancel', threadID: thread },
		})
	})

	test('create defaults to medium and rejects unknown modes', () => {
		expect(parseCommand({ type: 'create', prompt: 'new' })).toEqual({
			ok: true,
			command: { type: 'create', prompt: 'new', mode: 'medium' },
		})
		expect(parseCommand({ type: 'create', prompt: 'new', mode: 'turbo' })).toEqual({
			ok: false,
			reason: 'unknown mode turbo',
		})
	})

	test('rejects what it must', () => {
		const cases: Array<[unknown, string]> = [
			['{not json', 'body is not JSON'],
			[[1, 2], 'body is not an object'],
			[{ type: 'launch', threadID: thread, prompt: 'x' }, 'unknown command type launch'],
			[{ type: 'prompt', prompt: 'x' }, 'threadID missing or malformed'],
			[{ type: 'prompt', threadID: 'T-short', prompt: 'x' }, 'threadID missing or malformed'],
			[{ type: 'cancel', threadID: `${thread}; rm -rf /` }, 'threadID missing or malformed'],
			[{ type: 'prompt', threadID: thread, prompt: '   ' }, 'prompt empty'],
			[{ type: 'prompt', threadID: thread, prompt: 'x'.repeat(MAX_PROMPT_LENGTH + 1) }, 'prompt too long'],
			[{ type: 'prompt', threadID: thread }, 'prompt missing'],
		]
		for (const [input, reason] of cases) {
			expect(parseCommand(input)).toEqual({ ok: false, reason })
		}
	})

	test('a prompt of exactly the limit is accepted', () => {
		const result = parseCommand({ type: 'prompt', threadID: thread, prompt: 'y'.repeat(MAX_PROMPT_LENGTH) })
		expect(result.ok).toBe(true)
	})
})

describe('SeenEvents', () => {
	test('second delivery of the same id is a repeat', () => {
		const seen = new SeenEvents()
		expect(seen.markSeen('evt-1')).toBe(true)
		expect(seen.markSeen('evt-1')).toBe(false)
		expect(seen.markSeen('evt-2')).toBe(true)
	})

	test('forgets the oldest id once over capacity, and only that one', () => {
		const seen = new SeenEvents(2)
		seen.markSeen('a')
		seen.markSeen('b')
		expect(seen.markSeen('b')).toBe(false) // still within capacity
		seen.markSeen('c') // evicts a, keeps b and c
		expect(seen.markSeen('c')).toBe(false)
		expect(seen.markSeen('b')).toBe(false)
		expect(seen.markSeen('a')).toBe(true)
	})
})

describe('parseCommand: register and announce', () => {
	test('register normalises the token to lower case and defaults to sandbox', () => {
		const result = parseCommand({ type: 'register', deviceToken: 'AB'.repeat(32) })
		expect(result).toEqual({
			ok: true,
			command: { type: 'register', deviceToken: 'ab'.repeat(32), environment: 'sandbox' },
		})
	})

	test('register rejects a token that is not 64 hex characters', () => {
		expect(parseCommand({ type: 'register', deviceToken: 'ab'.repeat(31) }).ok).toBe(false)
		expect(parseCommand({ type: 'register', deviceToken: 'zz'.repeat(32) }).ok).toBe(false)
		expect(parseCommand({ type: 'register' }).ok).toBe(false)
	})

	test('announce keeps title and summary optional and rejects unknown outcomes', () => {
		expect(parseCommand({ type: 'announce', threadID: thread, outcome: 'done', summary: '  ok  ' })).toEqual({
			ok: true,
			command: { type: 'announce', threadID: thread, outcome: 'done', title: null, summary: 'ok' },
		})
		expect(parseCommand({ type: 'announce', threadID: thread, outcome: 'running' }).ok).toBe(false)
		expect(parseCommand({ type: 'announce', outcome: 'done' }).ok).toBe(false)
	})
})
