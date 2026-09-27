"""Rebuild the ANIM60 AP-only experiment from public source; never accesses a device."""
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
subprocess.run([sys.executable, research / 'animation-runtime-v1/build_candidate.py', '--out', candidate], check=True, env=env)
subprocess.run([sys.executable, research / 'animation-runtime-v1/check.py', '--candidate', candidate,
                '--out', out / 'checks'], check=True, env=env)
report = json.loads((candidate / 'report.json').read_text())
tested_ap = '68c8f2949e6fb17d41b5d71d1221a303c83f0b29b8f5aabd5487cca0da0dc9ad'
if report['candidateAP'] != tested_ap:
    raise SystemExit('Rebuilt AP differs from the tested ANIM60 AP; do not flash this ZIP.')
ap = candidate / 'payload/nuttx_ap.bin'
if hashlib.sha256(ap.read_bytes()).hexdigest() != tested_ap:
    raise SystemExit('AP payload hash mismatch.')
print('ANIM60 offline build and tests passed; AP matches tested bytes. ZIP timestamps may differ.')
print('No device operation or flash authorization was performed.')
