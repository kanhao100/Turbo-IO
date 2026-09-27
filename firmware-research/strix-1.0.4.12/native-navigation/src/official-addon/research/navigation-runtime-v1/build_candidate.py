"""New AP-only candidate via existing hash-pinned builder. Never installs/OTA."""
import argparse,importlib.util,json,sys,subprocess
from pathlib import Path
HERE=Path(__file__).resolve().parent;SRC=HERE.parent
sys.path.insert(0,str(SRC));sys.path.insert(0,str(HERE))
import menu9_profile
p=argparse.ArgumentParser();p.add_argument('--out',type=Path,required=True);args=p.parse_args()
spec=importlib.util.spec_from_file_location('candidate',SRC/'build-image-rx-candidate.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
m.native_menu=menu9_profile
try:m.build(args.out.resolve(),wide=True,native_eight=True,display_runtime=True,navigation_runtime=True)
except subprocess.CalledProcessError as e:
    print((e.stderr or b'').decode(errors='replace'),file=sys.stderr);raise
