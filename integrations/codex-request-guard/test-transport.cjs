const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const test = require('node:test');

// Exercise the installed Codex transport function, replacing only the final
// native boundary. Never load the Electron worker or send real Apple Events.
const directory = path.resolve(process.argv[2]);
const source = fs.readFileSync(path.join(directory, 'worker.js'), 'utf8');
const start = source.indexOf('async function r7(');
const end = source.indexOf('function Rve(', start);
assert(start >= 0 && end > start);
const transport = source.slice(start, end);

function fixture({allowed = true, runtimeChangesState = false, authorizationError = null} = {}) {
  const calls = [];
  let ready = allowed;
  const gate = {async assertReady() {
    calls.push('check');
    if (!ready) { const e = new Error('DESKTOP_DEFERRED'); e.code = 'DESKTOP_DEFERRED'; throw e; }
  }};
  const context = {
    process: {platform: 'darwin'}, Error,
    require: name => { assert.equal(name, './lightwake-request-guard.cjs'); return gate; },
    Ove: async () => { calls.push('runtime'); if (runtimeChangesState) ready = false; return 'native-runtime'; },
    Rve: parameters => { calls.push({native: parameters}); if (authorizationError) throw authorizationError; return 'original-result'; },
  };
  const invoke = vm.runInNewContext(transport + ';r7;', context);
  return {invoke, calls};
}

for (const requestType of [
  'ComputerUseIPCCodexStatusItemMenuStateRequest',
  'ComputerUseIPCAppGetSkyshotRequest',
  'ComputerUseIPCAppStartCaptureRequest',
  'ComputerUseIPCAppNextCaptureUpdateRequest',
  'ComputerUseIPCSkysightStartRequest',
  'ComputerUseIPCSkysightStatusRequest',
]) {
  test(`dark desktop rejects ${requestType} before native work`, async () => {
    const f = fixture({allowed: false});
    await assert.rejects(f.invoke({request: {}, requestType, serviceProcessIdentifier: 123, timeoutSeconds: 15}),
      e => e.code === 'DESKTOP_DEFERRED');
    assert.deepEqual(f.calls, ['check']);
  });
}
test('screen becoming unavailable during runtime initialization prevents send', async () => {
  const f = fixture({runtimeChangesState: true});
  await assert.rejects(f.invoke({request: {}, requestType: 'state', serviceProcessIdentifier: 123, timeoutSeconds: 15}),
    e => e.code === 'DESKTOP_DEFERRED');
  assert.deepEqual(f.calls, ['check', 'runtime', 'check']);
});
test('ready desktop preserves request, timeout, target and original response', async () => {
  const f = fixture();
  const payload = {app: 'test.example'};
  assert.equal(await f.invoke({request: payload, requestType: 'state', serviceProcessIdentifier: 123, timeoutSeconds: 7}), 'original-result');
  const sent = f.calls.find(v => v.native).native;
  assert.equal(sent.request, payload);
  assert.equal(sent.requestType, 'state');
  assert.equal(sent.serviceProcessIdentifier, 123);
  assert.equal(sent.timeoutSeconds, 7);
  assert.equal(sent.runtime, 'native-runtime');
  assert.equal(f.calls.filter(v => v.native).length, 1);
});
test('original authorization denial remains a denial', async () => {
  const denied = new Error('ORIGINAL_AUTHORIZATION_DENIED');
  const f = fixture({authorizationError: denied});
  await assert.rejects(f.invoke({request: {}, requestType: 'state', serviceProcessIdentifier: 123, timeoutSeconds: 7}), e => e === denied);
});

const main = fs.readFileSync(path.join(directory, 'main-C5K7o1Hr.js'), 'utf8');
const methodStart = main.indexOf('async ensureServicePidForEnabledFeatures(){');
const methodEnd = main.indexOf('}};function tre(', methodStart);
assert(methodStart >= 0 && methodEnd > methodStart);
test('dark desktop does not respawn the native service', async () => {
  let spawned = 0;
  const fn = vm.runInNewContext('({' + main.slice(methodStart, methodEnd + 1) + '})', {
    require: name => { assert.equal(name, './lightwake-request-guard.cjs'); return {async assertReady() {
      const e = new Error('DESKTOP_DEFERRED'); e.code = 'DESKTOP_DEFERRED'; throw e;
    }}; },
  }).ensureServicePidForEnabledFeatures;
  await assert.rejects(fn.call({servicePid: null, hasSpawnedService: false,
    spawnService: async () => { spawned++; return 456; },
    logger: () => ({info(){}, warning(){}}), onServiceAvailable(){}, onServiceRespawned(){}}),
    e => e.code === 'DESKTOP_DEFERRED');
  assert.equal(spawned, 0);
});
