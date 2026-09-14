import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

function readDesktopStatus() {
  const checker = fileURLToPath(new URL('./quiet_desktop_check.py', import.meta.url));
  try {
    return JSON.parse(execFileSync('/usr/bin/python3', [checker], {
      encoding: 'utf8', timeout: 5000, maxBuffer: 16384, stdio: ['ignore', 'pipe', 'pipe'],
    }));
  } catch (error) {
    if (error.status === 2) {
      try {
        const status = JSON.parse(String(error.stdout));
        if (status.allowed === false) return status;
      } catch {}
    }
    return { allowed: false, reason: 'status_unavailable' };
  }
}

// The underlying Sky client still performs its normal authorization checks.
// This preflight never invokes the service while the desktop is unsuitable.
export function createQuietSky(sky, probe = readDesktopStatus) {
  return new Proxy(sky, {
    get(target, property, receiver) {
      const value = Reflect.get(target, property, receiver);
      if (typeof value !== 'function') return value;
      return async (...args) => {
        let status;
        try { status = await probe(); } catch {}
        if (status?.allowed !== true) {
          throw new Error(`DESKTOP_DEFERRED (${status?.reason ?? 'status_unavailable'}): ` +
            'Keep the display asleep and the session locked as they are. ' +
            'Continue background work; defer this desktop check. ' +
            'Do not retry through the unguarded client or wake/unlock the screen.');
        }
        return Reflect.apply(value, target, args);
      };
    },
  });
}
