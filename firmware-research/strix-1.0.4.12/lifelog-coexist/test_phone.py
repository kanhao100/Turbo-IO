"""macOS offline OTA tests. Uses loopback only, never a phone/glasses connection."""
import argparse
import json
import subprocess
import tempfile
import zipfile
from pathlib import Path
from audit_firmware import audit

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--tlc1', type=Path, required=True)
p.add_argument('--tgr1', type=Path, required=True)
p.add_argument('--stock', type=Path, required=True)
a = p.parse_args()
audit(a.tlc1, a.stock)
import hashlib
assert hashlib.sha256(a.tgr1.read_bytes()).hexdigest() == '79e56482f4b3688d527ac2ef9c43d7157e6e0767a2d9625aeefe58033808c2ac'
src = Path(__file__).resolve().parent / 'ios-reference'
with tempfile.TemporaryDirectory(prefix='tlc1-offline-') as temporary:
    root = Path(temporary)
    for name, archive in [('tlc1', a.tlc1), ('tgr1', a.tgr1)]:
        with zipfile.ZipFile(archive) as z:
            # Exact pinned archives already checked; no arbitrary ZIP extraction.
            z.extractall(root / name)
    core = ['ExperimentalOTA.m', 'ExperimentalOTAFlash.m', 'ExperimentalOTAGuard.m']
    tests = {
        'archive': (['ExperimentalOTATests.m', 'ExperimentalOTA.m'], [a.tlc1, a.tgr1]),
        'directory': (['ExperimentalOTADirectoryTests.m', 'ExperimentalOTA.m'], [root/'tlc1', root/'tgr1']),
        'flash': (['ExperimentalOTAFlashTests.m'] + core, [root/'tlc1', root/'tgr1']),
        'guard': (['ExperimentalOTAGuardTests.m', 'ExperimentalOTAGuard.m'], []),
        'feed': (['ExperimentalOTAFeedTests.m', 'ExperimentalOTAFeed.m'] + core, [a.tlc1]),
    }
    for name, (sources, args) in tests.items():
        command = ['xcrun', 'clang', '-fobjc-arc', '-fmodules', '-Wno-deprecated-declarations',
                   '-framework', 'Foundation', '-lz', '-I', str(src)]
        if name == 'feed':
            command += ['-DTIO_OTA_FEED_ARMING_ENABLED=1']
        result = subprocess.run(command + [str(src/s) for s in sources] + ['-o', str(root/name)], capture_output=True, text=True)
        if result.returncode:
            raise RuntimeError(result.stderr)
        subprocess.run([str(root/name), *map(str,args)], check=True, timeout=60)
        print(name + ': PASS', flush=True)
print(json.dumps({'passed': True, 'suites': list(tests), 'deviceIO': False}))
