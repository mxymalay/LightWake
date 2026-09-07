const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const {createGuard} = require('./lightwake-request-guard.cjs');

const ready = {allowed: true, locked: false, on_console: true, lightwake_active: false, displays_asleep: [false]};
async function fixture(run) {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'lightwake-policy-'));
  const preferencesPath = path.join(directory, 'choice.json');
  const choose = value => fs.writeFile(preferencesPath, JSON.stringify(value), {mode: 0o600});
  try { await run({preferencesPath, choose}); }
  finally { await fs.rm(directory, {recursive: true, force: true}); }
}
test('fresh install creates nothing and makes no desktop calls', () => fixture(async ({preferencesPath}) => {
  const guard = createGuard({preferencesPath, platform: 'darwin', checkDesktop: () => assert.fail('must remain inert')});
  await guard.assertReady();
  await assert.rejects(fs.stat(preferencesPath), {code: 'ENOENT'});
}));
test('explicit opt-out takes effect on the next call without probing', () => fixture(async ({preferencesPath, choose}) => {
  let probes = 0;
  const guard = createGuard({preferencesPath, platform: 'darwin', checkDesktop: async () => { probes++; return ready; }});
  await choose({enabled: true, consentVersion: 1});
  await guard.assertReady();
  await choose({enabled: false, consentVersion: 1});
  await guard.assertReady();
  assert.equal(probes, 1);
}));
for (const [name, state] of [
  ['locked', {...ready, locked: true}],
  ['off console', {...ready, on_console: false}],
  ['lightwake active', {...ready, lightwake_active: true}],
  ['one sleeping monitor', {...ready, displays_asleep: [false, true]}],
  ['no monitors', {...ready, displays_asleep: []}],
  ['malformed monitor', {...ready, displays_asleep: [0]}],
  ['incomplete ready response', {allowed: true}],
  ['explicit denial', {...ready, allowed: false}],
]) {
  test(`${name} defers the call`, () => fixture(async ({preferencesPath, choose}) => {
    await choose({enabled: true, consentVersion: 1});
    const guard = createGuard({preferencesPath, platform: 'darwin', checkDesktop: async () => state});
    await assert.rejects(guard.assertReady(), {code: 'DESKTOP_DEFERRED'});
  }));
}
test('probe failure cannot dispatch a native request', () => fixture(async ({preferencesPath, choose}) => {
  await choose({enabled: true, consentVersion: 1});
  const guard = createGuard({preferencesPath, platform: 'darwin', checkDesktop: async () => { throw Error('probe failed'); }});
  await assert.rejects(guard.assertReady(), {code: 'DESKTOP_DEFERRED'});
}));
test('unknown consent is rejected before checking the desktop', () => fixture(async ({preferencesPath, choose}) => {
  await choose({enabled: true, consentVersion: 999});
  const guard = createGuard({preferencesPath, platform: 'darwin', checkDesktop: () => assert.fail('must not probe')});
  await assert.rejects(guard.assertReady(), {code: 'DESKTOP_DEFERRED'});
}));
test('broken preference is not silently interpreted as opt-out', () => fixture(async ({preferencesPath}) => {
  await fs.writeFile(preferencesPath, '{');
  const guard = createGuard({preferencesPath, platform: 'darwin', checkDesktop: () => assert.fail('must not probe')});
  await assert.rejects(guard.assertReady(), {code: 'DESKTOP_DEFERRED'});
}));
test('every call rereads desktop state', () => fixture(async ({preferencesPath, choose}) => {
  await choose({enabled: true, consentVersion: 1});
  let state = ready;
  const guard = createGuard({preferencesPath, platform: 'darwin', checkDesktop: async () => state});
  await guard.assertReady();
  state = {...ready, locked: true};
  await assert.rejects(guard.assertReady(), {code: 'DESKTOP_DEFERRED'});
  state = ready;
  await guard.assertReady();
}));
