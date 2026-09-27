"""Offline tests only: host sanitizers, exact candidate ARM execution and byte audit."""
import argparse,hashlib,json,subprocess,sys
from pathlib import Path
HERE=Path(__file__).resolve().parent;SRC=HERE.parent;ROOT=HERE.parents[2];DISPLAY=SRC/'display-runtime-v1'
p=argparse.ArgumentParser();p.add_argument('--out',type=Path,required=True);p.add_argument('--candidate',type=Path,required=True);a=p.parse_args()
out=a.out.resolve();out.mkdir(parents=True,exist_ok=False,mode=0o700)
def run(cmd,name):
 r=subprocess.run([str(v) for v in cmd],capture_output=True,text=True)
 (out/(name+'.log')).write_text(r.stdout+r.stderr)
 if r.returncode:raise RuntimeError(name+' failed; see '+str(out))
 return r.stdout
flags=['xcrun','clang','-std=c11','-O1','-g','-Wall','-Wextra','-Werror','-fsanitize=address,undefined']
run(flags+[HERE/'animation.c',HERE/'animation_test.c','-o',out/'core'],'compile-core')
core=run([out/'core'],'core')
native=[DISPLAY/(s+'.c') for s in ['display_runtime','display_client','display_carrier','native_display_page','native_display_file','native_display_test']]+[SRC/'image-upload-test/render_idle.c']
for name,extra in [('native-original',[]),('native-animation',['-DTIO_ANIMATION_EXPERIMENT',HERE/'animation.c'])]:
 run(flags+['-DTDP_NATIVE_HOST_TEST',*extra,*native,'-o',out/name],'compile-'+name)
 run([out/name],name)
for script,name,extra in [(DISPLAY/'test_linked_arm.py','display-arm',['--candidate']),
 (SRC/'navigation-runtime-v1/test_menu9_arm.py','menu-arm',[]),
 (SRC/'navigation-runtime-v1/test_service_arm.py','navigation-arm',[])]:
 run([sys.executable,script,a.candidate,*extra],name)
audit=json.loads(run([sys.executable,SRC/'audit-image-rx-candidate.py',a.candidate],'byte-audit'))
record={'status':'offline-passed','physicalFPSMeasured':False,'deviceIO':False,'flashed':False,
 'readyToFlash':False,'reason':'Private phone gate not prepared; fresh flash approval required',
 'core':core.strip(),'APOnlyAudit':audit,
 'sourceSHA256':{str(f.relative_to(ROOT)):hashlib.sha256(f.read_bytes()).hexdigest()
   for folder in [HERE,DISPLAY] for f in folder.iterdir() if f.is_file()}}
(out/'receipt.json').write_text(json.dumps(record,indent=2)+'\n')
print(json.dumps({k:v for k,v in record.items() if k!='sourceSHA256'},indent=2))
