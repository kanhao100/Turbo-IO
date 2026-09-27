"""Rebuild/audit in a NEW local directory using public sources only. No device IO."""
import argparse
import importlib.util
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path
from verify import verify

HERE = Path(__file__).resolve().parent
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--stock', type=Path, required=True, help='Exact published ORIGINAL-rollback.zip baseline')
p.add_argument('--out', type=Path, required=True, help='New workspace; never overwrite an existing directory')
p.add_argument('--llvm', type=Path, required=True, help='Matching OHOS LLVM 15.0.4 bin directory; see BUILD.md')
a = p.parse_args()
os.environ['PATH'] = str(a.llvm.resolve()) + os.pathsep + os.environ.get('PATH', '')
version = subprocess.check_output([a.llvm.resolve()/'clang', '--version'], text=True)
if 'OHOS (dev) clang version 15.0.4 (llvm-project 39bec79f56c3b5a629e4bacac1dc022e1da552d0)' not in version:
    raise SystemExit('Compiler differs from tested build; no release-equivalence claim. Read BUILD.md.')
out = a.out.resolve()
if out.exists():
    raise SystemExit('Output exists; choose a new directory. Nothing deleted.')
for tool in ('clang', 'ld.lld', 'llvm-nm', 'llvm-objcopy', 'node'):
    if not shutil.which(tool):
        raise SystemExit('Missing tool: '+tool+'; read BUILD.md')
shutil.copytree(HERE/'src', out)
subprocess.run([sys.executable, HERE.parent/'src/prepare-baseline.py', a.stock.resolve(),
                '--output', out/'firmware-inspection/StrixOS-1.0.4.12'], check=True)
shutil.copyfile(HERE/'symbols.json', out/'firmware-inspection/StrixOS-1.0.4.12/symbols.json')
png = out/'official-addon/build/turbo-photo-png-10412-20260921/turbo-photo-gray16-rgba-88x98.png'
png.parent.mkdir(parents=True)
shutil.copyfile(HERE.parent/'assets/turbo-photo-firmware.png', png)
research = out/'official-addon/research'
candidate = out/'candidate'
subprocess.run([sys.executable, research/'navigation-runtime-v1/build_candidate.py', '--out', candidate], check=True)
subprocess.run([sys.executable, research/'navigation-runtime-v1/test_menu9_arm.py', candidate], check=True)
subprocess.run([sys.executable, research/'navigation-runtime-v1/test_service_arm.py', candidate], check=True)
subprocess.run([sys.executable, research/'display-runtime-v1/test_linked_arm.py', candidate, '--candidate'], check=True)
subprocess.run([sys.executable, research/'audit-image-rx-candidate.py', candidate, '--out', candidate/'independent-audit.json'], check=True)
report = json.loads((candidate/'report.json').read_text())
print(json.dumps(verify(candidate/report['archive']['name'], rebuilt=True), indent=2))
print('Build and offline checks passed. Rebuilt ZIP timestamps may differ; phone accepts only the exact published ZIP. No flash authorized.')
