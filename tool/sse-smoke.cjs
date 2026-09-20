const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const { once } = require('node:events');
const fs = require('node:fs');
const net = require('node:net');
const http = require('node:http');
const https = require('node:https');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');

const executable = path.resolve(process.argv[2]);
const home = fs.mkdtempSync(path.join(os.tmpdir(), 'FlClashSSE-smoke-'));
let fail = false;
const sockets = new Set();
const processes = new Set();
const services = [];
const watchdog = setTimeout(() => { console.error('smoke deadline exceeded'); cleanup(); process.exit(1); }, 29000);
function cleanup() {
  clearTimeout(watchdog);
  for (const socket of sockets) socket.destroy();
  for (const service of services) service.close();
  for (const child of processes) child.kill();
}

async function proxy() {
  const server = http.createServer((_, response) => response.writeHead(405).end());
  services.push(server);
  server.on('connect', (request, client, head) => {
    sockets.add(client); client.on('close', () => sockets.delete(client));
    client.on('error', () => {});
    if (fail) { client.end('HTTP/1.1 502 Test failure\r\nConnection: close\r\n\r\n'); return; }
    const attach = (upstream, remainder = Buffer.alloc(0)) => {
      sockets.add(upstream); upstream.on('close', () => sockets.delete(upstream));
      upstream.on('error', () => client.destroy());
      client.on('close', () => upstream.destroy());
      client.write('HTTP/1.1 200 Connection established\r\n\r\n');
      if (head.length) upstream.write(head);
      if (remainder.length) client.write(remainder);
      client.pipe(upstream); upstream.pipe(client);
    };
    const configured = process.env.HTTPS_PROXY || process.env.https_proxy;
    if (configured) {
      const url = new URL(configured);
      const headers = {};
      if (url.username) headers['Proxy-Authorization'] = 'Basic ' + Buffer.from(decodeURIComponent(url.username) + ':' + decodeURIComponent(url.password)).toString('base64');
      const connect = (url.protocol === 'https:' ? https : http).request({ hostname: url.hostname, port: url.port || (url.protocol === 'https:' ? 443 : 80), method: 'CONNECT', path: request.url, headers, timeout: 6000 });
      connect.on('connect', (response, socket, remainder) => {
        if (response.statusCode !== 200) { socket.destroy(); client.destroy(); return; }
        attach(socket, remainder);
      });
      connect.on('error', () => client.destroy());
      connect.on('timeout', () => connect.destroy());
      connect.end();
    } else {
      const url = new URL('https://' + request.url);
      const upstream = net.connect({ host: url.hostname, port: Number(url.port || 443) });
      upstream.on('error', () => client.destroy());
      upstream.once('connect', () => attach(upstream));
    }
  });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  return server.address().port;
}

async function startCore() {
  const address = '\\\\.\\pipe\\FlClashCore_' + crypto.randomBytes(16).toString('hex');
  const server = net.createServer(); services.push(server);
  server.listen(address); await once(server, 'listening');
  const pendingConnection = once(server, 'connection');
  const child = spawn(executable, [address], { windowsHide: true, stdio: ['ignore', 'ignore', 'pipe'] });
  processes.add(child); child.on('exit', () => processes.delete(child));
  let stderr = ''; child.stderr.on('data', data => { stderr = (stderr + data).slice(-4096); });
  child.on('error', error => console.error(error.message));
  const [socket] = await pendingConnection;
  sockets.add(socket); socket.on('close', () => sockets.delete(socket));
  const waiting = new Map(); let buffer = Buffer.alloc(0), sequence = 0;
  socket.on('data', chunk => {
    buffer = Buffer.concat([buffer, chunk]);
    while (buffer.length >= 4 && buffer.length >= buffer.readUInt32LE(0) + 4) {
      const length = buffer.readUInt32LE(0), message = JSON.parse(buffer.subarray(4, 4 + length));
      buffer = buffer.subarray(4 + length);
      const receiver = waiting.get(message.id);
      if (receiver) { waiting.delete(message.id); message.error ? receiver.reject(Error(message.error.message)) : receiver.resolve(message.result); }
    }
  });
  function call(method, args) {
    const id = 'smoke-' + ++sequence;
    const result = new Promise((resolve, reject) => waiting.set(id, { resolve, reject }));
    const data = Buffer.from(JSON.stringify({ id, method, arguments: args }));
    const prefix = Buffer.alloc(4); prefix.writeUInt32LE(data.length); socket.write(Buffer.concat([prefix, data]));
    return result;
  }
  await call('initClash', { 'home-dir': home, version: 0 });
  return { call, async close() {
    socket.end();
    const exit = once(child, 'exit');
    const timer = setTimeout(() => child.kill(), 1500);
    await exit; clearTimeout(timer);
    server.close();
    if (stderr.includes('panic:')) throw Error(stderr);
  } };
}

(async () => {
  const ports = await Promise.all([proxy(), proxy()]);
  fs.mkdirSync(path.join(home, 'profiles'));
  const node = (name, port) => `  - {name: ${name}, type: http, server: 127.0.0.1, port: ${port}}\n`;
  fs.writeFileSync(path.join(home, 'profiles/1.yaml'), 'proxies:\n' + node('node-one', ports[0]) + '\nproxy-groups:\n  - {name: Select, type: select, proxies: [node-one]}\n');
  fs.writeFileSync(path.join(home, 'profiles/2.yaml'), 'proxies:\n' + node('same-node-renamed', ports[0]) + node('node-two', ports[1]));
  let core = await startCore();
  const start = Date.now();
  const initial = await core.call('sseBatch', { profiles: [1, 2] });
  assert.equal(initial.error, undefined);
  assert.equal(initial.nodes.length, 2);
  assert.equal(initial.nodes.reduce((n, node) => n + node.aliases.length, 0), 3);
  assert.equal(initial.issues.length, 0);
  const before = {};
  for (const node of initial.nodes) {
    const record = initial.history[node.key];
    assert.equal(record.latest.status, 'done', JSON.stringify(record.latest));
    assert.equal(record.lastSuccess.tokens, 161);
    assert.equal(record.lastSuccess.flowPass, true, 'complete streams must also be usable startup candidates');
    assert.ok(record.lastSuccess.tokPerSec > 0);
    before[node.key] = record.lastSuccess.tokPerSec;
  }
  const duration = Date.now() - start; assert.ok(duration < 20000);
  await core.close();
  fail = true;
  core = await startCore();
  const restored = await core.call('sseCatalog', { profiles: [1, 2] });
  for (const [key, speed] of Object.entries(before)) assert.equal(restored.history[key].lastSuccess.tokPerSec, speed);
  const failed = await core.call('sseBatch', { profiles: [1, 2] });
  for (const [key, speed] of Object.entries(before)) {
    assert.notEqual(failed.history[key].latest.status, 'done');
    assert.equal(failed.history[key].lastSuccess.tokPerSec, speed);
  }
  await core.close();
  const disk = JSON.parse(fs.readFileSync(path.join(home, 'sse-history-v1.json'), 'utf8'));
  for (const [key, speed] of Object.entries(before)) assert.equal(disk.results[key].lastSuccess.tokPerSec, speed);
  console.log(JSON.stringify({ success: true, nodes: 2, memberships: 3, elapsedMs: duration, restoredAfterRestart: true, preservedAfterFailure: true, home }));
})().catch(error => { console.error(error.message); process.exitCode = 1; }).finally(cleanup);
