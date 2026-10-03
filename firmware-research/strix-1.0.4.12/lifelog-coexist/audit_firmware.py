"""Read-only validation of the exact TLC1 release; never contacts a device."""
import argparse
import hashlib
import json
import re
import zipfile
from pathlib import Path


def require(condition, message):
    if not condition:
        raise ValueError(message)


def audit(archive, stock):
    sha = lambda data: hashlib.sha256(data).hexdigest()
    raw = archive.read_bytes()
    require(len(raw) == 9322471, 'ZIP length mismatch')
    require(sha(raw) == '5e2b85acb9cd25e0b245838e665e39d291eae4aae640308f126718eb3185e519', 'ZIP hash mismatch')
    original_ap = (stock / 'nuttx_ap.bin').read_bytes()
    require(sha(original_ap) == '53afdf5298815849eafca6f315a70606d2a605aff2e563f79050f797d615a988', 'Wrong stock AP')
    with zipfile.ZipFile(archive) as z:
        names = z.namelist()
        require(len(names) == len(set(names)) == 15, 'Wrong member count')
        require(all(Path(n).name == n and '/' not in n and '\\' not in n for n in names), 'Unexpected path')
        require(z.testzip() is None, 'ZIP CRC failure')
        members = {n: z.read(n) for n in names}
    manifest = json.loads(members['OtaFileInfo.json'])
    baseline = json.loads((stock / 'OtaFileInfo.json').read_bytes())
    require(len(manifest) == len(baseline) == 14, 'Wrong manifest count')
    require(set(members) == {e['Name'] for e in baseline} | {'OtaFileInfo.json'}, 'Unexpected payload')
    unchanged = []
    for entry, before in zip(manifest, baseline):
        name = entry['Name']
        require(name == before['Name'], 'Manifest order/name mismatch')
        data = members[name]
        require(len(data) == entry['Size'], 'Payload size mismatch: ' + name)
        require(hashlib.md5(data).hexdigest() == entry['Md5'], 'Payload MD5 mismatch: ' + name)
        if name == 'nuttx_ap.bin':
            require(len(data) == 9593736 and len(data) < 9_600_000, 'AP size/budget mismatch')
            require(sha(data) == 'bb3fee35ac7ff7f5b76295235323249634cdaf582069972d7b89cff4020f855d', 'AP hash mismatch')
            require({k: v for k, v in entry.items() if k not in ('Size', 'Md5')} ==
                    {k: v for k, v in before.items() if k not in ('Size', 'Md5')}, 'AP burn fields changed')
        else:
            require(entry == before and data == (stock / name).read_bytes(), 'Non-AP change: ' + name)
            unchanged.append(name)
    # Do not print matched bytes. Stock crypto libraries contain PEM literals.
    # This is a pattern check, not a proof of absence of every possible secret.
    patterns = (
        rb'sk-(?:ws-|tinyfish-)?[A-Za-z0-9_.-]{18,}', rb'wrk-[A-Za-z0-9]{16,}',
        rb'-----BEGIN [A-Z ]*PRIVATE KEY-----', rb'wr_skey=[^;\s\x00]{8,}',
        rb'MUSIC_U=[^;\s\x00]{16,}', rb'/' + rb'Users/[^/\s\x00]+/',
        rb'llm-[a-z0-9-]+\.[a-z0-9.-]*aliyuncs\.com',
    )
    for name, data in members.items():
        stock_data = (stock / name).read_bytes()
        for pattern in patterns:
            for match in re.finditer(pattern, data):
                require(match[0] in stock_data, 'New sensitive pattern in ' + name)
    require(len(unchanged) == 13, 'Non-AP count mismatch')
    return dict(candidate='TLC1-01', auditDate='2026-09-30',
                zipBytes=len(raw), zipSHA256=sha(raw), apBytes=9593736,
                apSHA256=sha(members['nuttx_ap.bin']), apMD5=hashlib.md5(members['nuttx_ap.bin']).hexdigest(),
                apBudgetBytes=9600000, apBudgetHeadroomBytes=6264,
                unchangedNonAPPayloads=unchanged, manifestValid=True, archiveValid=True,
                newSensitivePatternMatches=0,
                members={n: dict(bytes=len(d), sha256=sha(d)) for n, d in members.items()},
                validation=dict(userReportedFlashComplete=True, userReportedLifeLogMenuCoexistence=True,
                                userReportedMusicDisplayAfterGuardGuidance=True,
                                sustainedCaptureValidated=False, audioCoexistenceValidated=False,
                                repeatedHeadUpValidated=False, longRunValidated=False,
                                inheritedKnownIssue='TGR1 global paging remains unresolved.',
                                artifactRebuiltForUpload=False))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive', type=Path)
    parser.add_argument('stock', type=Path)
    parser.add_argument('--out', type=Path)
    args = parser.parse_args()
    result = json.dumps(audit(args.archive, args.stock), ensure_ascii=False, indent=2) + '\n'
    if args.out:
        with args.out.open('x') as out:
            out.write(result)
    print(result)
