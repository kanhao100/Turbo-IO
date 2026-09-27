"""Rebuild exact FOCUS-04 AP and test offline. No device access or OTA authorization."""
import argparse,hashlib,json,os,shutil,subprocess,sys
from pathlib import Path
HERE=Path(__file__).resolve().parent
def main():
 p=argparse.ArgumentParser(description=__doc__)
 for key in ('stock','out','llvm'):p.add_argument('--'+key,type=Path,required=True)
 a=p.parse_args();out=a.out.resolve();llvm=a.llvm.resolve()
 if out.exists():raise SystemExit('Fresh output required; nothing overwritten')
 version=subprocess.check_output([llvm/'clang','--version'],text=True)
 if 'OHOS (dev) clang version 15.0.4 (llvm-project 39bec79f56c3b5a629e4bacac1dc022e1da552d0)' not in version:raise SystemExit('Compiler differs from tested build')
 env=dict(os.environ,PATH=str(llvm)+os.pathsep+os.environ.get('PATH',''))
 def run(*cmd):subprocess.run([str(x) for x in cmd],check=True,env=env)
 shutil.copytree(HERE/'src',out)
 baseline=out/'firmware-inspection/StrixOS-1.0.4.12'
 run(sys.executable,HERE.parent.parent/'src/prepare-baseline.py',a.stock.resolve(),'--output',baseline)
 shutil.copyfile(HERE/'symbols.json',baseline/'symbols.json')
 png=out/'official-addon/build/turbo-photo-png-10412-20260921/turbo-photo-gray16-rgba-88x98.png'
 png.parent.mkdir(parents=True);shutil.copyfile(HERE.parent.parent/'assets/turbo-photo-firmware.png',png)
 src=out/'official-addon/research';candidate=out/'candidate'
 run(sys.executable,src/'music-runtime-v1/build_candidate.py','--out',candidate)
 for script in ('focus-v1/test_menu_quad_arm.py','focus-v1/test_menu12_arm.py','focus-v1/test_service_arm.py','weread-v1/test_reader_arm.py','weread-v1/test_open_lifecycle_arm.py','weread-v1/test_back_offline_arm.py','music-runtime-v1/test_music_arm.py','navigation-runtime-v1/test_service_arm.py','diagnostics-v1/test_service_arm.py'):
  run(sys.executable,src/script,candidate)
 run(sys.executable,src/'display-runtime-v1/test_linked_arm.py',candidate,'--candidate')
 run(sys.executable,src/'focus-v1/audit_candidate.py',candidate,'--out',candidate/'independent-audit.json')
 for name,units in [('focus',['focus.c','test_focus.c']),('focus-view',['focus.c','focus_view.c','test_view.c'])]:
  run('xcrun','clang','-std=c11','-Wall','-Wextra','-Werror','-fsanitize=address,undefined',*[src/'focus-v1'/u for u in units],'-o',out/name);run(out/name)
 expected=json.loads((HERE/'release-manifest.json').read_text());ap=(candidate/'payload/nuttx_ap.bin').read_bytes()
 if len(ap)>9600000 or hashlib.sha256(ap).hexdigest()!=expected['apSHA256']:raise SystemExit('AP differs; STOP, do not change pins')
 report=json.loads((candidate/'report.json').read_text())
 run(sys.executable,HERE/'verify.py',candidate/report['archive']['name'],'--rebuilt')
 print('Exact AP rebuilt; offline tests passed. No device I/O or flash authorization.')
if __name__=='__main__':main()
