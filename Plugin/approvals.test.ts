import { describe, expect, test } from 'bun:test'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { ApprovalQueue, DESTRUCTIVE_PATTERNS, MAX_INPUT_LENGTH, needsWatchApproval, renderInput } from './approvals'

describe('DESTRUCTIVE_PATTERNS', () => {
	test('match the list the watch warns about, in order', () => {
		const swift = readFileSync(
			join(import.meta.dir, '..', 'Packages', 'AmpKit', 'Sources', 'AmpKit', 'Model', 'PendingApproval.swift'),
			'utf8',
		)
		const start = swift.indexOf('= [', swift.indexOf('destructivePatterns:'))
		const block = swift.slice(start, swift.indexOf('\n    ]', start))
		const swiftPatterns = [...block.matchAll(/\("([^"]+)", "[^"]+"\)/g)].map((match) => match[1])
		expect(swiftPatterns.length).toBeGreaterThan(10)
		expect(DESTRUCTIVE_PATTERNS).toEqual(swiftPatterns)
	})
})

describe('renderInput', () => {
	test('a shell command shows the command with its directory, not the JSON', () => {
		expect(renderInput('shell_command', { command: 'git push', workdir: '/repo', timeout_ms: 5 })).toEqual({
			text: '/repo $ git push',
			complete: true,
		})
	})

	test('other tools show their JSON input', () => {
		const rendered = renderInput('create_file', { path: '/a', content: 'x' })
		expect(rendered.complete).toBe(true)
		expect(JSON.parse(rendered.text)).toEqual({ path: '/a', content: 'x' })
	})

	test('a long command is cut at the limit and marked incomplete', () => {
		const rendered = renderInput('shell_command', { command: 'x'.repeat(MAX_INPUT_LENGTH + 1) })
		expect(rendered.text.length).toBe(MAX_INPUT_LENGTH)
		expect(rendered.complete).toBe(false)
		expect(renderInput('shell_command', { command: 'x'.repeat(MAX_INPUT_LENGTH) }).complete).toBe(true)
	})
})

describe('needsWatchApproval', () => {
	test('off never holds, even the worst command', () => {
		expect(needsWatchApproval('off', 'shell_command', { command: 'rm -rf /' })).toBe(false)
	})

	test('risky holds destructive shell commands and lets harmless ones through', () => {
		expect(needsWatchApproval('risky', 'shell_command', { command: 'git push --force' })).toBe(true)
		expect(needsWatchApproval('risky', 'shell_command', { command: 'RM -RF build' })).toBe(true)
		expect(needsWatchApproval('risky', 'shell_command', { command: 'ls -la' })).toBe(false)
	})

	test('a destructive string in a file edit is not a shell command and is not held', () => {
		expect(needsWatchApproval('all', 'create_file', { path: '/x', content: 'rm -rf /' })).toBe(false)
	})

	test('all holds every shell command', () => {
		expect(needsWatchApproval('all', 'shell_command', { command: 'ls' })).toBe(true)
		expect(needsWatchApproval('all', 'Bash', { command: 'ls' })).toBe(true)
	})
})

describe('ApprovalQueue', () => {
	const request = (id: string) => ({
		id,
		threadID: 'T-1',
		toolName: 'shell_command',
		input: 'ls',
		inputIsComplete: true,
		requestedAt: 0,
	})

	test('approve and reject resolve the waiting call and forget it', async () => {
		const queue = new ApprovalQueue()
		const a = queue.wait(request('a'), 1000)
		const b = queue.wait(request('b'), 1000)
		expect(queue.pending().map((r) => r.id)).toEqual(['a', 'b'])
		expect(queue.decide('b', 'reject')).toBe(true)
		expect(queue.decide('a', 'approve')).toBe(true)
		expect(await a).toBe('approve')
		expect(await b).toBe('reject')
		expect(queue.pending()).toEqual([])
		expect(queue.decide('a', 'approve')).toBe(false)
	})

	test('defer acknowledges but keeps waiting; the timeout then wins', async () => {
		const queue = new ApprovalQueue()
		const outcome = queue.wait(request('a'), 30)
		expect(queue.decide('a', 'defer')).toBe(true)
		expect(queue.pending()).toHaveLength(1)
		expect(await outcome).toBe('timeout')
		expect(queue.pending()).toEqual([])
	})

	test('a decision for an unknown call is reported as such', () => {
		expect(new ApprovalQueue().decide('nope', 'approve')).toBe(false)
	})

	test('cancel resolves a waiting call as a timeout', async () => {
		const queue = new ApprovalQueue()
		const outcome = queue.wait(request('a'), 10_000)
		queue.cancel('a')
		expect(await outcome).toBe('timeout')
	})
})
