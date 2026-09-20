import { strict as assert } from 'node:assert';
import { test } from 'node:test';
import worker, { frame, endFrame, profile, samples } from './worker.mjs';

test('all 161 fixed frames carry a complete monotonic protocol', () => {
  for (let i = 0; i < samples; i++) {
    const text = frame(i, i * 50 + 0.2);
    assert.equal(Buffer.byteLength(text), 256);
    const data = JSON.parse(text.split('\n')[1].slice(6));
    assert.equal(data.seq, i);
    assert.equal(data.scheduledMs, i * 50);
    assert.equal(data.sentMs, i * 50 + 0.2);
  }
  assert.deepEqual(JSON.parse(endFrame().split('\n')[1].slice(6)), { profile, samples });
});

test('only SSE is served; no model or download endpoints', async () => {
  for (const path of ['/api/chat', '/v1/responses', '/download']) {
    const response = await worker.fetch(new Request(`https://example.com${path}`));
    assert.equal(response.status, 404);
  }
  assert.equal((await worker.fetch(new Request('https://example.com/api/stream', { method: 'POST' }))).status, 404);
});

test('cancelled streams release the source slot', async () => {
  const response = await worker.fetch(new Request('https://example.com/api/stream'));
  assert.equal(response.headers.get('x-stream-quality-profile'), profile);
  assert.equal(response.headers.get('cache-control'), 'no-store, no-transform');
  await response.body.cancel();
  const health = await (await worker.fetch(new Request('https://example.com/health'))).json();
  assert.equal(health.active, 0);
});
