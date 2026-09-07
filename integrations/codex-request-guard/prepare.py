"""Prepare a version-pinned, review-only Codex source patch. No app is modified."""
from pathlib import Path
import argparse
import hashlib
import json
import shutil
import struct

ROOT = Path(__file__).resolve().parent
EXPECTED_HEADER = '3f7cb0a2856ec33e9240b111f3d475123d237a7f8198b39c8160f7ea3ffaa733'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--codex-app', type=Path, default=Path('/Applications/ChatGPT.app'))
    parser.add_argument('--output', type=Path, default=ROOT.parents[1]/'.build/codex-request-guard')
    args = parser.parse_args()
    output = args.output.resolve()
    if any(p.suffix.lower() == '.app' for p in [output, *output.parents]):
        parser.error('Output must not be inside an application bundle')
    if output.exists():
        parser.error('Choose a new output directory; existing files are never replaced')
    archive = args.codex_app / 'Contents/Resources/app.asar'
    # Reading a sealed bundle does not alter its signatures or authorization.
    with archive.open('rb') as stream:
        _, header_size, _, json_size = struct.unpack('<4I', stream.read(16))
        header_bytes = stream.read(json_size)
        if hashlib.sha256(header_bytes).hexdigest() != EXPECTED_HEADER:
            raise RuntimeError('Unsupported Codex archive header; re-review the current version')
        entries = json.loads(header_bytes)
        originals = {}
        for name in ['worker.js', 'main-C5K7o1Hr.js']:
            entry = entries['files']['.vite']['files']['build']['files'][name]
            stream.seek(8 + header_size + int(entry['offset']))
            originals[name] = stream.read(entry['size']).decode('utf8')
    marker = 'async function r7({request:e,requestType:t,serviceProcessIdentifier:n,timeoutSeconds:r}){'
    runtime = 'return Rve({request:e,requestType:t,runtime:await Ove(),serviceProcessIdentifier:n,timeoutSeconds:r})'
    gate = 'await require("./lightwake-request-guard.cjs").assertReady();'
    worker = originals['worker.js']
    for expected in [marker, runtime]:
        if worker.count(expected) != 1: raise RuntimeError('Native transport anchor changed')
    # Recheck after lazy runtime initialization: it may outlive the first check.
    worker = worker.replace(marker, marker + gate, 1)
    worker = worker.replace(runtime, 'const lightwakeRuntime=await Ove();' + gate
        + 'return Rve({request:e,requestType:t,runtime:lightwakeRuntime,serviceProcessIdentifier:n,timeoutSeconds:r})', 1)
    main_source = originals['main-C5K7o1Hr.js']
    spawn = 'async ensureServicePidForEnabledFeatures(){'
    if main_source.count(spawn) != 1: raise RuntimeError('Service lifecycle anchor changed')
    main_source = main_source.replace(spawn, spawn + gate, 1)
    patched = {'worker.js': worker, 'main-C5K7o1Hr.js': main_source}
    output.mkdir(parents=True)
    baseline = output/'baseline'; baseline.mkdir()
    for name, source in originals.items(): (baseline/name).write_text(source)
    for name, source in patched.items(): (output/name).write_text(source)
    shutil.copy2(ROOT/'lightwake-request-guard.cjs', output/'lightwake-request-guard.cjs')
    probe = ROOT.parents[1]/'apps/screen-guard/resources/quiet-desktop/quiet_desktop_check.py'
    shutil.copy2(probe, output/'quiet_desktop_check.py')
    manifest = {'codex_version': '26.901.41600', 'codex_build': '7982',
        'archive_header_sha256': EXPECTED_HEADER,
        'installed_app_modified': False, 'ready_for_activation': False,
        'reason': 'Requires original distribution integration/signing and live compatibility validation',
        'default_enabled': False, 'request_queue': False, 'process_signals': False,
        'original_sha256': {n: hashlib.sha256(s.encode()).hexdigest() for n,s in originals.items()},
        'patched_sha256': {n: hashlib.sha256(s.encode()).hexdigest() for n,s in patched.items()}}
    (output/'manifest.json').write_text(json.dumps(manifest, indent=2)+'\n')
    # Minified bundles have very long lines. Summarize exact replacement sites
    # instead of embedding the entire proprietary bundle in a diff or report.
    (output/'changes.txt').write_text('worker.js: gate before native runtime initialization and before Rve dispatch.\n'
        'main-C5K7o1Hr.js: gate before managed-service reuse/respawn.\n'
        'Original native transport, sender identity and authorization are unchanged.\n')
    print(json.dumps(manifest))


if __name__ == '__main__': main()
