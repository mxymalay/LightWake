'use strict';
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const {execFile} = require('node:child_process');
const {promisify} = require('node:util');
const execute = promisify(execFile);

function deferred(reason) {
  const error = new Error(`DESKTOP_DEFERRED (${reason}): native desktop work was not sent. Continue background work; retry desktop work only after the user returns.`);
  error.code = 'DESKTOP_DEFERRED';
  return error;
}

async function probe() {
  let output;
  try {
    const result = await execute('/usr/bin/python3', [path.join(__dirname, 'quiet_desktop_check.py')],
      {encoding: 'utf8', timeout: 3000, maxBuffer: 16384, windowsHide: true});
    output = result.stdout;
  } catch (error) {
    if (error.code !== 2) throw deferred('status_unavailable');
    output = error.stdout;
  }
  try { return JSON.parse(output); }
  catch { throw deferred('status_unavailable'); }
}

function createGuard({
  preferencesPath = path.join(os.homedir(), 'Library/Application Support/ScreenGuard/codex-request-guard.json'),
  checkDesktop = probe,
  platform = process.platform,
} = {}) {
  return {async assertReady() {
    if (platform !== 'darwin') return;
    let preferences;
    try {
      if ((await fs.stat(preferencesPath)).size > 4096) throw deferred('invalid_preference');
      preferences = JSON.parse(await fs.readFile(preferencesPath, 'utf8'));
    } catch (error) {
      if (error.code === 'ENOENT') return; // New installations are off.
      throw deferred('invalid_preference');
    }
    if (preferences?.enabled === false) return;
    if (preferences?.enabled !== true || preferences.consentVersion !== 1) {
      throw deferred('invalid_preference');
    }
    let state;
    try { state = await checkDesktop(); }
    catch { throw deferred('status_unavailable'); }
    if (state?.allowed !== true || state.locked !== false || state.on_console !== true
        || state.lightwake_active !== false || !Array.isArray(state.displays_asleep)
        || state.displays_asleep.length === 0 || state.displays_asleep.some(asleep => asleep !== false)) {
      throw deferred('desktop_not_ready');
    }
  }};
}

module.exports = {createGuard, assertReady: createGuard().assertReady};
