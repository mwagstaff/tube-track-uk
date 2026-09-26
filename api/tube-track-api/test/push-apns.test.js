import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { EventEmitter } from 'node:events';
import test from 'node:test';
import {
    ApnsClient,
    ApnsTokenSigner,
    isDeadTokenResponse,
    liveActivityPayload
} from '../lib/push/apns.js';

const { privateKey, publicKey } = crypto.generateKeyPairSync('ec', {
    namedCurve: 'prime256v1',
    privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
    publicKeyEncoding: { type: 'spki', format: 'pem' }
});

function signer(clock) {
    return new ApnsTokenSigner({
        keyId: 'KEY123456',
        teamId: 'TEAM12345',
        privateKey,
        clock
    });
}

function decodeSegment(segment) {
    return JSON.parse(Buffer.from(segment, 'base64url').toString('utf8'));
}

test('the provider token verifies as a JOSE ES256 signature', () => {
    const token = signer(() => 1_800_000_000_000).token();
    const [header, payload, signature] = token.split('.');

    assert.deepEqual(decodeSegment(header), {
        alg: 'ES256',
        kid: 'KEY123456',
        typ: 'JWT'
    });
    assert.deepEqual(decodeSegment(payload), { iss: 'TEAM12345', iat: 1_800_000_000 });

    const signatureBytes = Buffer.from(signature, 'base64url');
    // RFC 7515 ES256 is the raw r||s pair, 32 bytes each — not ASN.1 DER, which
    // is what crypto.sign produces if you forget to say otherwise.
    assert.equal(signatureBytes.length, 64);
    assert.equal(
        crypto.verify(
            'sha256',
            Buffer.from(`${header}.${payload}`),
            { key: publicKey, dsaEncoding: 'ieee-p1363' },
            signatureBytes
        ),
        true
    );
});

test('provider tokens are reused until they approach Apple’s one-hour limit', () => {
    let now = 1_800_000_000_000;
    const subject = signer(() => now);

    const first = subject.token();
    now += 54 * 60 * 1_000;
    assert.equal(subject.token(), first, 'a token still inside its life is reused');

    now += 2 * 60 * 1_000;
    assert.notEqual(subject.token(), first, 'a token past 55 minutes is re-minted');
});

class FakeRequest extends EventEmitter {
    constructor() {
        super();
        this.body = null;
        this.closed = false;
    }

    setEncoding() {}

    setTimeout(ms, handler) {
        this.timeoutMs = ms;
        this.timeoutHandler = handler;
    }

    close() {
        this.closed = true;
    }

    end(body) {
        this.body = body;
    }
}

function fakeSession() {
    const session = new EventEmitter();
    session.requests = [];
    session.closed = false;
    session.destroyed = false;
    session.setTimeout = () => {};
    session.unref = () => {};
    session.close = () => {
        session.closed = true;
    };
    session.request = (headers) => {
        const request = new FakeRequest();
        request.headers = headers;
        session.requests.push(request);
        return request;
    };
    return session;
}

function clientWith(session, overrides = {}) {
    let connections = 0;
    const client = new ApnsClient({
        signer: signer(() => 1_800_000_000_000),
        environment: 'sandbox',
        connect: () => {
            connections += 1;
            return session;
        },
        ...overrides
    });
    return { client, connections: () => connections };
}

function respond(request, { status, body }) {
    request.emit('response', { ':status': status, 'apns-id': 'apns-1' });
    if (body) request.emit('data', body);
    request.emit('end');
}

test('a Live Activity send carries the headers and payload Apple requires', async () => {
    const session = fakeSession();
    const { client } = clientWith(session);

    const pending = client.send({
        token: 'abc123',
        topic: 'dev.skynolimit.TubeTrackUK.push-type.liveactivity',
        pushType: 'liveactivity',
        priority: 10,
        expiration: 1_800_003_600,
        payload: liveActivityPayload({
            contentState: { departures: [], sequence: 4 },
            timestampSeconds: 1_800_000_000,
            staleDateSeconds: 1_800_000_300,
            relevanceScore: 80
        })
    });

    const request = session.requests[0];
    assert.equal(request.headers[':path'], '/3/device/abc123');
    assert.equal(request.headers['apns-push-type'], 'liveactivity');
    assert.equal(request.headers['apns-priority'], '10');
    assert.equal(request.headers['apns-expiration'], '1800003600');
    assert.match(request.headers.authorization, /^bearer ey/);

    const body = JSON.parse(request.body.toString('utf8'));
    // content-state belongs inside aps, and the times are epoch seconds.
    assert.deepEqual(body.aps['content-state'], { departures: [], sequence: 4 });
    assert.equal(body.aps.timestamp, 1_800_000_000);
    assert.equal(body.aps['stale-date'], 1_800_000_300);
    assert.equal(body.aps.event, 'update');

    respond(request, { status: 200 });
    const result = await pending;
    assert.equal(result.ok, true);
    assert.equal(result.dead, false);
    assert.equal(result.retryable, false);
});

test('one HTTP/2 session is shared across sends', async () => {
    const session = fakeSession();
    const { client, connections } = clientWith(session);

    const first = client.send({ token: 'a', topic: 't', pushType: 'liveactivity', payload: {} });
    respond(session.requests[0], { status: 200 });
    await first;

    const second = client.send({ token: 'b', topic: 't', pushType: 'liveactivity', payload: {} });
    respond(session.requests[1], { status: 200 });
    await second;

    assert.equal(connections(), 1);
});

test('a dead token is reported as dead rather than retryable', async () => {
    const session = fakeSession();
    const { client } = clientWith(session);

    const pending = client.send({ token: 'a', topic: 't', pushType: 'liveactivity', payload: {} });
    respond(session.requests[0], { status: 410, body: '{"reason":"Unregistered"}' });
    const result = await pending;

    assert.equal(result.dead, true);
    assert.equal(result.retryable, false);
    assert.equal(result.reason, 'Unregistered');
});

test('mixed development and production tokens use separate reusable sessions', async () => {
    const sessions = new Map();
    const client = new ApnsClient({
        signer: signer(() => 1_800_000_000_000),
        environment: 'production',
        connect: (host) => {
            assert.equal(sessions.has(host), false, 'each host should connect only once');
            const session = fakeSession();
            sessions.set(host, session);
            return session;
        }
    });
    for (const environment of ['production', 'sandbox', 'production', 'sandbox']) {
        const pending = client.send({ token: 'a', topic: 't', pushType: 'liveactivity', payload: {}, environment });
        const host = environment === 'sandbox'
            ? 'https://api.sandbox.push.apple.com:443' : 'https://api.push.apple.com:443';
        respond(sessions.get(host).requests.at(-1), { status: 200 });
        assert.equal((await pending).ok, true);
    }
    assert.equal(sessions.size, 2);
    assert.equal(client.environment, 'production');
    client.close();
    assert.ok([...sessions.values()].every((session) => session.closed));
});

test('throttling and outages are retryable, a rejected payload is not', async () => {
    const session = fakeSession();
    const { client } = clientWith(session);

    const throttled = client.send({ token: 'a', topic: 't', pushType: 'liveactivity', payload: {} });
    respond(session.requests[0], { status: 429, body: '{"reason":"TooManyRequests"}' });
    assert.equal((await throttled).retryable, true);

    const rejected = client.send({ token: 'a', topic: 't', pushType: 'liveactivity', payload: {} });
    respond(session.requests[1], { status: 400, body: '{"reason":"PayloadTooLarge"}' });
    const result = await rejected;
    assert.equal(result.retryable, false);
    assert.equal(result.dead, false);
});

test('dead-token classification covers every terminal reason', () => {
    assert.equal(isDeadTokenResponse({ status: 410, reason: null }), true);
    assert.equal(isDeadTokenResponse({ status: 400, reason: 'BadDeviceToken' }), true);
    assert.equal(isDeadTokenResponse({ status: 400, reason: 'Unregistered' }), true);
    assert.equal(isDeadTokenResponse({ status: 400, reason: 'PayloadTooLarge' }), false);
    assert.equal(isDeadTokenResponse({ status: 503, reason: 'ServiceUnavailable' }), false);
});

test('a request that never answers rejects rather than hanging', async () => {
    const session = fakeSession();
    const { client } = clientWith(session, { requestTimeoutMs: 25 });

    const pending = client.send({ token: 'a', topic: 't', pushType: 'liveactivity', payload: {} });
    session.requests[0].timeoutHandler();

    await assert.rejects(pending, /timed out/);
});
