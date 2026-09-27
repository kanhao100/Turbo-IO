"""Rebuild the TMU1 AP-only music experiment from public source; no device I/O."""
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

here = Path(__file__).resolve().parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--stock', type=Path, required=True, help='Exact Strix OS 1.0.4.12 original OTA ZIP')
parser.add_argument('--out', type=Path, required=True, help='Fresh output directory; never overwritten')
parser.add_argument('--llvm', type=Path, required=True, help='OHOS LLVM 15.0.4 bin directory')
args = parser.parse_args()
out = args.out.resolve()
if out.exists():
    raise SystemExit('Output exists; choose a new path. Nothing deleted.')
llvm = args.llvm.resolve()
version = subprocess.check_output([llvm / 'clang', '--version'], text=True)
if 'OHOS (dev) clang version 15.0.4 (llvm-project 39bec79f56c3b5a629e4bacac1dc022e1da552d0)' not in version:
    raise SystemExit('Compiler differs from the tested version; do not claim release equivalence.')
env = dict(os.environ, PATH=str(llvm) + os.pathsep + os.environ.get('PATH', ''))
for tool in ('clang', 'ld.lld', 'llvm-nm', 'llvm-objcopy', 'node'):
    if not shutil.which(tool, path=env['PATH']):
        raise SystemExit('Missing tool: ' + tool)
shutil.copytree(here / 'src', out)
baseline = out / 'firmware-inspection/StrixOS-1.0.4.12'
subprocess.run([sys.executable, here.parent / 'src/prepare-baseline.py', args.stock.resolve(),
                '--output', baseline], check=True, env=env)
shutil.copyfile(here / 'symbols.json', baseline / 'symbols.json')
png = out / 'official-addon/build/turbo-photo-png-10412-20260921/turbo-photo-gray16-rgba-88x98.png'
png.parent.mkdir(parents=True)
shutil.copyfile(here.parent / 'assets/turbo-photo-firmware.png', png)
research = out / 'official-addon/research'
candidate = out / 'candidate'
subprocess.run([sys.executable, research / 'music-runtime-v1/build_candidate.py', '--out', candidate], check=True, env=env)
for script, extra in [
    ('music-runtime-v1/test_music_arm.py', []),
    ('music-runtime-v1/test_menu10_arm.py', []),
    ('navigation-runtime-v1/test_service_arm.py', []),
    ('display-runtime-v1/test_linked_arm.py', ['--candidate']),
    ('audit-image-rx-candidate.py', ['--out', candidate / 'independent-audit.json'])]:
    subprocess.run([sys.executable, research / script, candidate, *extra], check=True, env=env)
host = out / 'music-core-test'
subprocess.run(['xcrun', 'clang', '-std=c11', '-O1', '-g', '-fsanitize=address,undefined',
                research / 'music-runtime-v1/music.c', research / 'music-runtime-v1/music_test.c', '-o', host], check=True)
subprocess.run([host], check=True)
report = json.loads((candidate / 'report.json').read_text())
tested_ap = '15da0e4ed255587f3b0f2dc422aff9c01d4ea48f3cf71c73407f3fcd6b2c936f'
if report['candidateAP'] != tested_ap:
    raise SystemExit('Rebuilt AP differs from the tested TMU1 AP; do not flash this ZIP.')
ap = candidate / 'payload/nuttx_ap.bin'
if hashlib.sha256(ap.read_bytes()).hexdigest() != tested_ap:
    raise SystemExit('AP payload hash mismatch.')
subprocess.run([sys.executable, here / 'music/verify.py', candidate / report['archive']['name'], '--rebuilt'], check=True)
print('TMU1 offline build and tests passed; AP matches tested bytes. ZIP timestamps may differ.')
print('No device operation or flash authorization was performed.')
