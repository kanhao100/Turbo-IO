"""Read-only, offline R3 package audit. PASS never authorizes or proves flashing.

Does not extract archives, alter firmware, contact devices, or send OTA messages.
Pins the exact published experiment and original baseline, not arbitrary firmware.
"""
import argparse
import hashlib
import io
import json
from pathlib import Path
import stat
import zipfile

ROOT = Path(__file__).resolve().parents[1]
BASELINE = ROOT / 'work/baseline'
ZIP_SHA = '658352deed03c27102ad4151b104389d7f19a7690c505486d188261a483a32ff'
AP_SHA = 'dbed42e8ef949ad5b0d327a2382c58a316ec31dff3b2dbbb90e442e695772268'
OLD_AP_SHA = '53afdf5298815849eafca6f315a70606d2a605aff2e563f79050f797d615a988'
MAX_ZIP = 16 * 1024 * 1024
MAX_TOTAL = 32 * 1024 * 1024


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, 'duplicate JSON key')
        result[key] = value
    return result


def parse_manifest(data):
    rows = json.loads(data, object_pairs_hook=unique_object)
    require(isinstance(rows, list) and len(rows) == 14, 'expected 14 payloads')
    names = set()
    for row in rows:
        require(isinstance(row, dict), 'invalid manifest row')
        name = row.get('Name')
        require(isinstance(name, str) and name not in ('', '.', '..')
                and '/' not in name and '\\' not in name and '\x00' not in name,
                'unsafe payload name')
        require(name not in names, 'duplicate payload name')
        names.add(name)
        require(type(row.get('Size')) is int and 0 < row['Size'] <= 11 * 1024 * 1024,
                'invalid payload size')
    return rows


def read_members(blob, expected):
    require(len(blob) <= MAX_ZIP, 'archive too large')
    with zipfile.ZipFile(io.BytesIO(blob)) as archive:
        entries = archive.infolist()
        names = [item.filename for item in entries]
        require(len(names) == len(set(names)), 'duplicate ZIP member')
        require(set(names) == expected, 'unexpected or missing ZIP members')
        require(sum(item.file_size for item in entries) <= MAX_TOTAL, 'expanded size limit')
        for item in entries:
            require(not item.flag_bits & 1, 'encrypted ZIP member')
            require(not item.is_dir(), 'directory member')
            mode = item.external_attr >> 16
            require(stat.S_IFMT(mode) in (0, stat.S_IFREG), 'nonregular ZIP member')
        return {name: archive.read(name) for name in names}


def audit_contents(members, original_rows, originals):
    rows = parse_manifest(members['OtaFileInfo.json'])
    require([r['Name'] for r in rows] == [r['Name'] for r in original_rows],
            'payload order/names changed')
    changed = []
    for row, original in zip(rows, original_rows):
        name = row['Name']
        data = members[name]
        require(len(data) == row['Size'], 'size mismatch: ' + name)
        require(hashlib.md5(data).hexdigest() == row.get('Md5'), 'MD5 mismatch: ' + name)
        permitted = {'Size', 'Md5'} if name == 'nuttx_ap.bin' else set()
        require({k: v for k, v in row.items() if k not in permitted}
                == {k: v for k, v in original.items() if k not in permitted},
                'manifest semantics changed: ' + name)
        if data != originals[name]:
            changed.append(name)
    require(changed == ['nuttx_ap.bin'], 'non-AP changes or AP unchanged')
    ap = members['nuttx_ap.bin']
    require(sha(ap) == AP_SHA, 'not the pinned R3 AP')
    require(ap[:16] == originals['nuttx_ap.bin'][:16], 'boot header changed')
    require(ap[-8:] == originals['nuttx_ap.bin'][-8:], 'terminal marker changed')
    require(len(ap) <= 0x9f0000, 'AP partition overflow')
    return {
        'offlineIntegrityPassed': True,
        'changedPayloads': changed,
        'unchangedPayloadCount': 13,
        'apBytes': len(ap),
        'apGrowthBytes': len(ap) - len(originals['nuttx_ap.bin']),
        'installManifestCandidates': [r['Name'] for r in rows if r['BurnMode'] in (1, 2)],
        'resourcePreparationCandidates': [r['Name'] for r in rows if r['BurnMode'] == 3],
        'installPlanEvidence': '1.0.4.12 AP 0x1080bb38 filters BurnMode 1/2; not an observed flash plan',
        'flashAuthorized': False,
        'deviceIO': False,
        'runtimeValidated': False,
        'unresolved': ['phone same-version local-package dispatch',
                       'Recovery installation and boot acceptance',
                       'appended address execution permission on hardware',
                       'native PNG decoding and physical display',
                       'recovery if Bluetooth/OTA stops working'],
    }


def audit(path):
    # Read bounded archive bytes once, checking what is actually audited.
    with path.open('rb') as stream:
        blob = stream.read(MAX_ZIP + 1)
    require(len(blob) <= MAX_ZIP, 'archive too large')
    require(sha(blob) == ZIP_SHA, 'not the approved R3 archive; do not flash')
    rows = parse_manifest((BASELINE / 'OtaFileInfo.json').read_bytes())
    baseline = json.loads((BASELINE / 'baseline.json').read_bytes())
    pins = {r['name']: r['sha256'] for r in baseline['files']}
    originals = {}
    for row in rows:
        name = row['Name']
        data = (BASELINE / name).read_bytes()
        require(sha(data) == pins[name], 'original baseline changed: ' + name)
        require(len(data) == row['Size'] and hashlib.md5(data).hexdigest() == row['Md5'],
                'original manifest mismatch: ' + name)
        originals[name] = data
    require(sha(originals['nuttx_ap.bin']) == OLD_AP_SHA, 'wrong original AP version')
    members = read_members(blob, set(originals) | {'OtaFileInfo.json'})
    result = audit_contents(members, rows, originals)
    result['archiveSHA256'] = sha(blob)
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive', type=Path)
    parser.add_argument('--baseline', type=Path, default=BASELINE)
    args = parser.parse_args()
    BASELINE = args.baseline
    try:
        print(json.dumps(audit(args.archive), ensure_ascii=False, indent=2))
    except (ValueError, OSError, KeyError, zipfile.BadZipFile) as exc:
        parser.exit(1, 'REFUSED: ' + str(exc) + '\n')
