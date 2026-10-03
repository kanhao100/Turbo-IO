"""Offline pack/verify of exact archived stock OTA payloads. Never flashes.

The source was an official-app unpacked OTA cache, not a verified original
server ZIP. Repacking changes the container, never the manifest or payloads.
Only explicit pinned filenames are read: no account data, logs or symbols.
"""
import argparse
import hashlib
import json
from pathlib import Path
import zipfile

PINS = dict(line.split() for line in '''
OtaFileInfo.json 9cc71ebd4ec1434619638c49cee2f7089df239763f9fa1e87f081d78d3f5e997
nuttx_ap.bin 53afdf5298815849eafca6f315a70606d2a605aff2e563f79050f797d615a988
nuttx_audio.bin 549a72c032595e3829da7d63b7e1fd13cceda1a55dfefa7a7cad02db5a9b42ab
cb_fw_venus.bin 8799f12071bdac082218e3601c24ab0989275fc2f7db74e37b8314a225c2cf7d
ota_installer_progress.bin 6fd65d296a667e1a7d94ec129adfd26458a4008ef403b331f855192c36eb3e3f
images.bin 192fefaa70545856884c89a9186e3f86d8f99a0738b201e116a11bc63011c158
lotties.bin ad66d83a3394034f825a12769aad292fc03e59fa865fe06bc43536b918a0b32b
rives.bin 836bc019f7152890b94cafafe2edaa024f317526318349f7833319e41158b104
nuttx_bth.bin a8f4594868bffbd3bc08a38d1f3899571608e2d57869d147de3d06f3e4f7a12a
fac_test_img.bin 18eb0901c3e0daeae48dd5f015252b6931ea7368f0160c2c985c4e74296d17eb
nuttx_apc1.bin 97d56ffc6dd575ad3d8bf7739d49e491ad7e4a959db8770b653f5302e171fb5c
smf.json 2713dc3a302a65c101fa981500cd8b217766c526b6045bf02db5e9e6763d076d
pil_algo_vad_demo.dll 7ac5b5191202adea20c62642987fa0049024dde9c386ba6cd08a1f29ddd5c92c
pil_algo_wakeup_dll_nand.dll d1594cb8658b228e52c2606d02f1eab696d35a11ed42ddcb725e76a745f5550f
pil_algo_up_demo_nand.dll e266726fe055ac6ec6f785a9440e8da7421402f2b4d3d7889039ad9b94e119c2
'''.strip().splitlines())
NAME = 'StrixOS-1.0.4.12-STOCK-PAYLOADS-REPACK.zip'

def sha(data):
    return hashlib.sha256(data).hexdigest()

def validate(files):
    if set(files) != set(PINS):
        raise ValueError('Wrong member set')
    for name, digest in PINS.items():
        if sha(files[name]) != digest:
            raise ValueError('Stock SHA-256 mismatch: ' + name)
    rows = json.loads(files['OtaFileInfo.json'])
    if len(rows) != 14 or {r['Name'] for r in rows} != set(PINS) - {'OtaFileInfo.json'}:
        raise ValueError('Manifest member set')
    for row in rows:
        data = files[row['Name']]
        if len(data) != row['Size'] or hashlib.md5(data).hexdigest() != row['Md5']:
            raise ValueError('Manifest size/MD5 mismatch')
    return rows

def read_zip(path):
    if path.stat().st_size > 25_000_000:
        raise ValueError('Oversize archive')
    with zipfile.ZipFile(path) as z:
        infos = z.infolist()
        if len(infos) != 15 or len({i.filename for i in infos}) != 15:
            raise ValueError('Member count/duplicates')
        if {i.filename for i in infos} != set(PINS):
            raise ValueError('Unexpected member')
        if sum(i.file_size for i in infos) > 19_000_000:
            raise ValueError('Expanded size budget')
        if any(i.is_dir() or i.flag_bits & 1 or (i.external_attr >> 16) & 0o170000 not in (0, 0o100000) for i in infos):
            raise ValueError('Directories, encryption and special files are not allowed')
        files = {i.filename: z.read(i) for i in infos}
    validate(files)
    return files

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    pack = sub.add_parser('pack')
    pack.add_argument('--directory', type=Path, required=True)
    pack.add_argument('--out', type=Path, required=True, help='New output directory')
    verify = sub.add_parser('verify')
    verify.add_argument('zip', type=Path)
    args = parser.parse_args()
    if args.command == 'verify':
        files = read_zip(args.zip)
        print(json.dumps({'verifiedStockMembers': len(files), 'zipSHA256': sha(args.zip.read_bytes()), 'deviceIO': False}))
        return
    if args.out.exists():
        raise ValueError('Refuse to overwrite any existing output')
    files = {}
    for name in PINS:
        path = args.directory / name
        if path.is_symlink() or not path.is_file() or path.stat().st_size > 10_000_000:
            raise ValueError('Invalid input file: ' + name)
        files[name] = path.read_bytes()
    rows = validate(files)
    args.out.mkdir(parents=True)
    archive = args.out / NAME
    # Fixed metadata, unmodified original manifest, manifest order for payloads.
    with zipfile.ZipFile(archive, 'x', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for name in ['OtaFileInfo.json'] + [r['Name'] for r in rows]:
            info = zipfile.ZipInfo(name, (2026, 9, 29, 0, 0, 0))
            info.create_system = 3
            info.external_attr = 0o100644 << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(info, files[name], compresslevel=9)
    assert read_zip(archive) == files
    report = dict(version='1.0.4.12', provenance='Archived official-app unpacked OTA cache; newly repacked ZIP',
        originalServerZipVerified=False, vendorSignatureVerified=False, archiveRepacked=True,
        payloadsModified=False, manifestModified=False, hardwareRestoreTested=False, deviceIO=False,
        archive=dict(name=NAME, bytes=archive.stat().st_size, sha256=sha(archive.read_bytes())),
        files=[dict(name=n, bytes=len(b), sha256=sha(b), md5=hashlib.md5(b).hexdigest()) for n,b in files.items()])
    (args.out/'stock-audit.json').write_text(json.dumps(report, indent=2)+'\n')
    (args.out/'SHA256SUMS.txt').write_text(''.join(f'{sha((args.out/n).read_bytes())}  {n}\n' for n in (NAME,'stock-audit.json')))
    print(json.dumps(report['archive'], indent=2))

if __name__ == '__main__':
    main()
