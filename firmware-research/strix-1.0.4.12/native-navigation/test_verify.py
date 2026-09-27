"""Adversarial offline ZIP checks; only UUID temp files are removed by tempfile."""
import argparse
import json
import tempfile
import zipfile
from pathlib import Path
from verify import verify

p = argparse.ArgumentParser()
p.add_argument('archive', type=Path)
a = p.parse_args()
assert verify(a.archive)['exactTestedZIP']
with zipfile.ZipFile(a.archive) as z:
    original = {n: z.read(n) for n in z.namelist()}
with tempfile.TemporaryDirectory(prefix='tnv1-verify-test-') as tmp:
    for scenario in ('other-payload', 'ap', 'manifest', 'missing', 'extra', 'traversal', 'duplicate'):
        members = dict(original)
        if scenario in ('other-payload', 'ap'):
            name = 'nuttx_bth.bin' if scenario == 'other-payload' else 'nuttx_ap.bin'
            b = bytearray(members[name]); b[100] ^= 1; members[name] = bytes(b)
        if scenario == 'manifest':
            j = json.loads(members['OtaFileInfo.json']); j[0]['Size'] += 1
            members['OtaFileInfo.json'] = json.dumps(j).encode()
        if scenario == 'missing': members.pop('smf.json')
        if scenario == 'extra': members['unexpected.txt'] = b'x'
        if scenario == 'traversal': members['../escape'] = b'x'
        f = Path(tmp)/(scenario+'.zip')
        with zipfile.ZipFile(f, 'w', compression=zipfile.ZIP_DEFLATED) as z:
            for n, b in members.items(): z.writestr(n, b)
            if scenario == 'duplicate': z.writestr('smf.json', members['smf.json'])
        try:
            verify(f, rebuilt=True)
        except ValueError:
            pass
        else:
            raise AssertionError('Accepted mutation: '+scenario)
print('PASS exact release and 7 adversarial archive/manifest/payload scenarios; no device IO')
