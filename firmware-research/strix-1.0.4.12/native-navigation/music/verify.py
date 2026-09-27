"""Read-only, bounded ZIP + manifest + AP-only release verification. Never flashes."""
import argparse
import hashlib
import json
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ZIP_SHA = '307a0d41aa76b3ed91a8fcc07b09329d76d78a51584c9954c7896d64b1ad9a81'
AP_SHA = '15da0e4ed255587f3b0f2dc422aff9c01d4ea48f3cf71c73407f3fcd6b2c936f'
AP_MD5 = '1d3edd747e409e52437755e876c39b37'

def verify(archive, rebuilt=False):
    if archive.stat().st_size > 12 * 1024 * 1024:
        raise ValueError('Archive too large')
    sha = hashlib.sha256(archive.read_bytes()).hexdigest()
    if not rebuilt and sha != ZIP_SHA:
        raise ValueError('Not the exact hardware-tested TMU1 ZIP; do not flash')
    baseline = json.loads((HERE.parent.parent/'metadata/baseline.json').read_text())
    pins = {r['name']: r for r in baseline['files']}
    with zipfile.ZipFile(archive) as z:
        infos = z.infolist()
        if len(infos) != 15 or set(z.namelist()) != set(pins) | {'OtaFileInfo.json'}:
            raise ValueError('Unexpected, duplicate or missing ZIP member')
        if any(i.flag_bits & 1 or i.file_size > 16*1024*1024 for i in infos) or sum(i.file_size for i in infos) > 40*1024*1024:
            raise ValueError('Invalid size or encrypted ZIP member')
        data = {i.filename: z.read(i) for i in infos}
    rows = json.loads(data['OtaFileInfo.json'])
    if len(rows) != 14 or {r['Name'] for r in rows} != set(pins):
        raise ValueError('Unexpected manifest')
    for row in rows:
        name = row['Name']; blob = data[name]
        expected = AP_SHA if name == 'nuttx_ap.bin' else pins[name]['sha256']
        if hashlib.sha256(blob).hexdigest() != expected:
            raise ValueError('Payload differs: '+name)
        if row['Size'] != len(blob) or row['Md5'] != hashlib.md5(blob).hexdigest():
            raise ValueError('Manifest size/MD5 differs: '+name)
    if len(data['nuttx_ap.bin']) != 9902600:
        raise ValueError('AP size differs')
    # Also pin the manifest bytes, so non-Size/MD5 fields cannot drift.
    manifest_sha = json.loads((HERE/'release-manifest.json').read_text())['manifestSHA256']
    if hashlib.sha256(data['OtaFileInfo.json']).hexdigest() != manifest_sha:
        raise ValueError('Manifest differs from tested release')
    return {'archiveSHA256': sha, 'exactTestedZIP': sha == ZIP_SHA, 'AP': AP_SHA,
            'apMD5': AP_MD5, 'unchangedStockPayloads': 13, 'deviceIO': False,
            'flashAuthorized': False}

if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('archive', type=Path)
    p.add_argument('--rebuilt', action='store_true', help='Compare rebuilt members only; does not authorize this ZIP in phone')
    a = p.parse_args()
    print(json.dumps(verify(a.archive, a.rebuilt), indent=2))
