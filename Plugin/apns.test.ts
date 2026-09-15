import { describe, expect, test } from 'bun:test'
import {
	buildPayload,
	buildProviderToken,
	buildRequest,
	isDeviceToken,
	readCredentials,
	tokenIsFresh,
	type ApnsCredentials,
} from './apns'

async function generateP8(): Promise<{ pem: string; publicKey: CryptoKey }> {
	const pair = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify'])
	const der = new Uint8Array(await crypto.subtle.exportKey('pkcs8', pair.privateKey))
	const base64 = btoa(String.fromCharCode(...der))
	const lines = base64.match(/.{1,64}/g) ?? []
	return {
		pem: ['-----BEGIN PRIVATE KEY-----', ...lines, '-----END PRIVATE KEY-----'].join('\n'),
		publicKey: pair.publicKey,
	}
}

function decodeSegment(segment: string): Record<string, unknown> {
	const padded = segment.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - (segment.length % 4)) % 4)
	return JSON.parse(atob(padded))
}

function segmentBytes(segment: string): Uint8Array<ArrayBuffer> {
	const padded = segment.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - (segment.length % 4)) % 4)
	const binary = atob(padded)
	const bytes = new Uint8Array(new ArrayBuffer(binary.length))
	for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i)
	return bytes
}

describe('readCredentials', () => {
	test('reports every missing variable, not just the first', () => {
		expect(readCredentials({ APNS_TEAM_ID: 'T' })).toEqual({ ok: false, missing: ['APNS_KEY_ID', 'APNS_P8'] })
	})

	test('unescapes a one-line p8 and defaults to sandbox', () => {
		const result = readCredentials({
			APNS_KEY_ID: ' K1 ',
			APNS_TEAM_ID: 'TEAM',
			APNS_P8: '-----BEGIN PRIVATE KEY-----\\nabc\\n-----END PRIVATE KEY-----',
		})
		expect(result.ok).toBe(true)
		if (!result.ok) return
		expect(result.credentials.keyID).toBe('K1')
		expect(result.credentials.p8.split('\n')).toHaveLength(3)
		expect(result.credentials.environment).toBe('sandbox')
	})

	test('anything but "production" means sandbox', () => {
		const env = { APNS_KEY_ID: 'K', APNS_TEAM_ID: 'T', APNS_P8: 'x', APNS_ENV: 'prod' }
		const result = readCredentials(env)
		expect(result.ok && result.credentials.environment).toBe('sandbox')
	})
})

describe('buildProviderToken', () => {
	test('produces an ES256 JWT that verifies against the matching public key', async () => {
		const { pem, publicKey } = await generateP8()
		const credentials: ApnsCredentials = { keyID: 'ABC123DEFG', teamID: 'TEAM567890', p8: pem, environment: 'sandbox' }
		const now = new Date('2026-09-15T08:00:00Z')

		const token = await buildProviderToken(credentials, now)
		const [header, claims, signature] = token.jwt.split('.')

		expect(decodeSegment(header)).toEqual({ alg: 'ES256', kid: 'ABC123DEFG' })
		expect(decodeSegment(claims)).toEqual({ iss: 'TEAM567890', iat: 1789459200 })
		expect(token.issuedAt).toBe(1789459200)
		// APNs wants the raw r‖s signature (64 bytes), not DER.
		expect(segmentBytes(signature)).toHaveLength(64)
		const valid = await crypto.subtle.verify(
			{ name: 'ECDSA', hash: 'SHA-256' },
			publicKey,
			segmentBytes(signature),
			new TextEncoder().encode(`${header}.${claims}`),
		)
		expect(valid).toBe(true)
	})

	test('a token signed with a different key does not verify', async () => {
		const signer = await generateP8()
		const other = await generateP8()
		const credentials: ApnsCredentials = { keyID: 'K', teamID: 'T', p8: signer.pem, environment: 'sandbox' }
		const [header, claims, signature] = (await buildProviderToken(credentials)).jwt.split('.')
		const valid = await crypto.subtle.verify(
			{ name: 'ECDSA', hash: 'SHA-256' },
			other.publicKey,
			segmentBytes(signature),
			new TextEncoder().encode(`${header}.${claims}`),
		)
		expect(valid).toBe(false)
	})

	test('a token is fresh for 50 minutes and stale at 50 minutes', () => {
		const token = { jwt: '', issuedAt: 1000 }
		expect(tokenIsFresh(token, new Date((1000 + 50 * 60 - 1) * 1000))).toBe(true)
		expect(tokenIsFresh(token, new Date((1000 + 50 * 60) * 1000))).toBe(false)
	})

	test('rejects a p8 that is not a key', async () => {
		const credentials: ApnsCredentials = { keyID: 'K', teamID: 'T', p8: '-----BEGIN PRIVATE KEY-----\n-----END PRIVATE KEY-----', environment: 'sandbox' }
		await expect(buildProviderToken(credentials)).rejects.toThrow()
	})
})

describe('buildPayload', () => {
	test('a finished thread carries its title, a clipped summary and the Continue category', () => {
		const payload = buildPayload({
			kind: 'thread-done',
			threadID: 'T-1',
			title: '  Fix CI  ',
			summary: 'Done.\n\nThe   build is green now and ' + 'x'.repeat(200),
		})
		expect(payload.aps.alert.title).toBe('Fix CI')
		expect(payload.aps.alert.body.startsWith('Done. The build is green now and ')).toBe(true)
		expect(payload.aps.alert.body.endsWith('…')).toBe(true)
		expect(payload.aps.alert.body.length).toBe(160)
		expect(payload.aps.category).toBe('THREAD_DONE')
		expect(payload.aps['thread-id']).toBe('T-1')
		expect(payload.approvalID).toBeUndefined()
	})

	test('an untitled thread with no summary still reads sensibly', () => {
		const payload = buildPayload({ kind: 'thread-error', threadID: 'T-2', title: null, summary: '   ' })
		expect(payload.aps.alert).toEqual({ title: 'Untitled thread', body: 'Stopped with an error' })
	})

	test('an approval is time-sensitive and names the tool', () => {
		const payload = buildPayload({
			kind: 'approval',
			threadID: 'T-3',
			title: 'Deploy',
			approvalID: 'A-9',
			toolName: 'shell_command',
			summary: 'rm -rf build',
		})
		expect(payload.aps.category).toBe('APPROVAL')
		expect(payload.aps['interruption-level']).toBe('time-sensitive')
		expect(payload.aps.alert.body).toBe('shell_command: rm -rf build')
		expect(payload.approvalID).toBe('A-9')
		expect(JSON.stringify(payload).length).toBeLessThan(4096)
	})
})

describe('buildRequest', () => {
	const credentials: ApnsCredentials = { keyID: 'K', teamID: 'T', p8: '', environment: 'production' }
	const providerToken = { jwt: 'h.c.s', issuedAt: 5000 }
	const deviceToken = 'ab'.repeat(32)

	test('targets the device on the environment host with the bearer token and topic', () => {
		const request = buildRequest({
			credentials,
			providerToken,
			deviceToken,
			event: { kind: 'thread-done', threadID: 'T-1', title: 't', summary: null },
		})
		expect(request.url).toBe(`https://api.push.apple.com/3/device/${deviceToken}`)
		expect(request.headers.authorization).toBe('bearer h.c.s')
		expect(request.headers['apns-topic']).toBe('com.soll.ampwatch.watchkitapp')
		expect(request.headers['apns-push-type']).toBe('alert')
		expect(request.headers['apns-expiration']).toBe(String(5000 + 600))
		expect(request.headers['apns-collapse-id']).toBe('T-1')
		expect(JSON.parse(request.body).threadID).toBe('T-1')
	})

	test('sandbox goes to the sandbox host', () => {
		const request = buildRequest({
			credentials: { ...credentials, environment: 'sandbox' },
			providerToken,
			deviceToken,
			event: { kind: 'thread-done', threadID: 'T-1', title: 't', summary: null },
		})
		expect(request.url.startsWith('https://api.sandbox.push.apple.com/')).toBe(true)
	})

	test('approvals are never collapsed into each other', () => {
		const request = buildRequest({
			credentials,
			providerToken,
			deviceToken,
			event: { kind: 'approval', threadID: 'T-1', title: 't', approvalID: 'A', toolName: 'x', summary: 'y' },
		})
		expect(request.headers['apns-collapse-id']).toBeUndefined()
	})
})

describe('isDeviceToken', () => {
	test('accepts 64 hex characters and nothing else', () => {
		expect(isDeviceToken('AB'.repeat(32))).toBe(true)
		expect(isDeviceToken('ab'.repeat(31))).toBe(false)
		expect(isDeviceToken('zz'.repeat(32))).toBe(false)
		expect(isDeviceToken(42)).toBe(false)
	})
})
