/**
 * Everything needed to send an APNs push, except the network call.
 *
 * Pure and unit-tested: the provider token (an ES256 JWT), the notification
 * payloads, and the exact HTTP request. `amp-watch-bridge.ts` performs the
 * request through `curl --http2`, which is what the orb has; no APNs library.
 *
 * Credentials come from environment variables and never from the repo:
 *
 *   APNS_KEY_ID   – the 10-character key ID from the developer portal
 *   APNS_TEAM_ID  – the 10-character team ID
 *   APNS_P8       – the .p8 file contents (PEM), newlines may be `\n` escapes
 *   APNS_ENV      – `sandbox` (default, Xcode builds) or `production`
 */

export const BUNDLE_ID = 'com.soll.ampwatch.watchkitapp'

/** Notification categories the watch registers, with their actions. */
export const CATEGORY = {
	/** A turn finished. Action: Continue. */
	threadDone: 'THREAD_DONE',
	/** A turn stopped with an error. Action: Retry. */
	threadError: 'THREAD_ERROR',
	/** A tool call waits for a decision. Actions: Approve, Reject. */
	approval: 'APPROVAL',
} as const

export type ApnsEnvironment = 'sandbox' | 'production'

export interface ApnsCredentials {
	keyID: string
	teamID: string
	/** PEM text of the .p8 private key. */
	p8: string
	environment: ApnsEnvironment
}

export type CredentialsResult = { ok: true; credentials: ApnsCredentials } | { ok: false; missing: string[] }

/** Reads credentials from an environment map; reports every missing variable at once. */
export function readCredentials(env: Record<string, string | undefined>): CredentialsResult {
	const missing = ['APNS_KEY_ID', 'APNS_TEAM_ID', 'APNS_P8'].filter((name) => !env[name]?.trim())
	if (missing.length > 0) return { ok: false, missing }
	const environment = env.APNS_ENV === 'production' ? 'production' : 'sandbox'
	return {
		ok: true,
		credentials: {
			keyID: env.APNS_KEY_ID!.trim(),
			teamID: env.APNS_TEAM_ID!.trim(),
			// A secret pasted into a one-line env var arrives with literal "\n".
			p8: env.APNS_P8!.replace(/\\n/g, '\n').trim(),
			environment,
		},
	}
}

export function apnsHost(environment: ApnsEnvironment): string {
	return environment === 'production' ? 'https://api.push.apple.com' : 'https://api.sandbox.push.apple.com'
}

// ---------------------------------------------------------------- provider token

/** APNs accepts a token for up to 60 minutes; refresh well before that. */
export const TOKEN_LIFETIME_SECONDS = 50 * 60

export interface ProviderToken {
	jwt: string
	/** Unix seconds the token was issued. */
	issuedAt: number
}

/**
 * Builds the JWT APNs authenticates providers with: header `{alg, kid}`,
 * claims `{iss, iat}`, ES256 over the P-256 key from the .p8 file.
 */
export async function buildProviderToken(credentials: ApnsCredentials, now = new Date()): Promise<ProviderToken> {
	const issuedAt = Math.floor(now.getTime() / 1000)
	const header = base64url(new TextEncoder().encode(JSON.stringify({ alg: 'ES256', kid: credentials.keyID })))
	const claims = base64url(new TextEncoder().encode(JSON.stringify({ iss: credentials.teamID, iat: issuedAt })))
	const signingInput = `${header}.${claims}`
	const key = await importPrivateKey(credentials.p8)
	// WebCrypto returns the raw r‖s concatenation, which is exactly what JWS
	// ES256 wants (no DER wrapping).
	const signature = await crypto.subtle.sign(
		{ name: 'ECDSA', hash: 'SHA-256' },
		key,
		new TextEncoder().encode(signingInput),
	)
	return { jwt: `${signingInput}.${base64url(new Uint8Array(signature))}`, issuedAt }
}

export function tokenIsFresh(token: ProviderToken, now = new Date()): boolean {
	return Math.floor(now.getTime() / 1000) - token.issuedAt < TOKEN_LIFETIME_SECONDS
}

async function importPrivateKey(pem: string): Promise<CryptoKey> {
	const body = pem
		.split('\n')
		.filter((line) => !line.startsWith('-----'))
		.join('')
		.trim()
	if (body.length === 0) throw new Error('APNS_P8 is not a PEM private key')
	const der = Uint8Array.from(atob(body), (c) => c.charCodeAt(0))
	return crypto.subtle.importKey('pkcs8', der, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign'])
}

export function base64url(bytes: Uint8Array): string {
	let binary = ''
	for (const byte of bytes) binary += String.fromCharCode(byte)
	return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

// ---------------------------------------------------------------- payloads

/** What the bridge tells the watch about. */
export type PushEvent =
	| { kind: 'thread-done'; threadID: string; title: string | null; summary: string | null }
	| { kind: 'thread-error'; threadID: string; title: string | null; summary: string | null }
	| { kind: 'approval'; threadID: string; title: string | null; approvalID: string; toolName: string; summary: string }

/** APNs rejects payloads over 4 KB; a one-line summary is plenty on a watch. */
const MAX_SUMMARY = 160

export interface ApnsPayload {
	aps: {
		alert: { title: string; body: string }
		category: string
		sound: 'default'
		'thread-id': string
		'interruption-level': 'active' | 'time-sensitive'
	}
	threadID: string
	approvalID?: string
}

export function buildPayload(event: PushEvent): ApnsPayload {
	const title = event.title?.trim() || 'Untitled thread'
	switch (event.kind) {
		case 'thread-done':
			return {
				aps: {
					alert: { title, body: clip(event.summary) ?? 'Finished' },
					category: CATEGORY.threadDone,
					sound: 'default',
					'thread-id': event.threadID,
					'interruption-level': 'active',
				},
				threadID: event.threadID,
			}
		case 'thread-error':
			return {
				aps: {
					alert: { title, body: clip(event.summary) ?? 'Stopped with an error' },
					category: CATEGORY.threadError,
					sound: 'default',
					'thread-id': event.threadID,
					'interruption-level': 'active',
				},
				threadID: event.threadID,
			}
		case 'approval':
			return {
				aps: {
					alert: { title, body: clip(`${event.toolName}: ${event.summary}`) ?? event.toolName },
					category: CATEGORY.approval,
					sound: 'default',
					'thread-id': event.threadID,
					// The agent is blocked until someone answers.
					'interruption-level': 'time-sensitive',
				},
				threadID: event.threadID,
				approvalID: event.approvalID,
			}
	}
}

function clip(text: string | null | undefined): string | null {
	const trimmed = text?.replace(/\s+/g, ' ').trim()
	if (!trimmed) return null
	return trimmed.length <= MAX_SUMMARY ? trimmed : trimmed.slice(0, MAX_SUMMARY - 1) + '…'
}

// ---------------------------------------------------------------- request

export interface ApnsRequest {
	url: string
	headers: Record<string, string>
	body: string
}

/**
 * The HTTP request for one push. `apns-collapse-id` is the thread ID, so a
 * later state of the same thread replaces the earlier notification instead of
 * stacking; approvals are not collapsed (each needs its own answer).
 */
export function buildRequest(options: {
	credentials: ApnsCredentials
	providerToken: ProviderToken
	deviceToken: string
	event: PushEvent
}): ApnsRequest {
	const payload = buildPayload(options.event)
	const headers: Record<string, string> = {
		authorization: `bearer ${options.providerToken.jwt}`,
		'apns-topic': BUNDLE_ID,
		'apns-push-type': 'alert',
		'apns-priority': '10',
		// Ten minutes: a state change older than that is stale on a wrist.
		'apns-expiration': String(options.providerToken.issuedAt + 10 * 60),
	}
	if (options.event.kind !== 'approval') headers['apns-collapse-id'] = options.event.threadID
	return {
		url: `${apnsHost(options.credentials.environment)}/3/device/${options.deviceToken}`,
		headers,
		body: JSON.stringify(payload),
	}
}

/** Device tokens are 32 bytes rendered as 64 hex characters. */
export function isDeviceToken(value: unknown): value is string {
	return typeof value === 'string' && /^[0-9a-f]{64}$/i.test(value)
}
