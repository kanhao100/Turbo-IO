"""Offline positive and rejection tests; never sends firmware."""
import copy
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import unittest
import warnings
import zipfile

spec = importlib.util.spec_from_file_location('gate', Path(__file__).with_name('preflight-menu8-ota.py'))
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)
PACKAGE = gate.ROOT / 'work/downloads'
ZIP = PACKAGE / 'StrixOS-1.0.4.12-TurboPhoto-menu8-EXPERIMENTAL-UNFLASHED.zip'


class PreflightTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.rows = gate.parse_manifest((gate.BASELINE / 'OtaFileInfo.json').read_bytes())
        cls.originals = {r['Name']: (gate.BASELINE / r['Name']).read_bytes() for r in cls.rows}
        cls.members = gate.read_members(ZIP.read_bytes(), set(cls.originals) | {'OtaFileInfo.json'})

    def changed_manifest(self, change):
        members = self.members.copy()
        rows = json.loads(members['OtaFileInfo.json'])
        change(rows)
        members['OtaFileInfo.json'] = json.dumps(rows).encode()
        return members

    def reject(self, members, message):
        with self.assertRaisesRegex(ValueError, message):
            gate.audit_contents(members, self.rows, self.originals)

    def test_real_r3(self):
        result = gate.audit(ZIP)
        self.assertEqual(result['apGrowthBytes'], 6816)
        self.assertEqual(result['installManifestCandidates'], [
            'nuttx_audio.bin', 'nuttx_ap.bin', 'nuttx_bth.bin', 'nuttx_apc1.bin',
            'smf.json', 'pil_algo_vad_demo.dll'])
        self.assertEqual(len(result['resourcePreparationCandidates']), 8)
        self.assertFalse(result['flashAuthorized'])
        self.assertFalse(result['runtimeValidated'])

    def test_original_and_superseded_not_approved(self):
        for path in [PACKAGE / 'StrixOS-1.0.4.12-ORIGINAL-rollback.zip']:
            with self.subTest(path=path.name), self.assertRaisesRegex(ValueError, 'approved R3'):
                gate.audit(path)

    def test_wrong_size(self):
        self.reject(self.changed_manifest(lambda rows: rows[2].update(Size=1)), 'size mismatch')

    def test_burn_destination_change(self):
        self.reject(self.changed_manifest(lambda rows: rows[2].update(BurnAddr='1')), 'semantics')

    def test_non_ap_change_even_with_correct_md5(self):
        members = self.members.copy()
        data = bytearray(members['nuttx_bth.bin'])
        data[32] ^= 1
        members['nuttx_bth.bin'] = bytes(data)
        rows = json.loads(members['OtaFileInfo.json'])
        next(r for r in rows if r['Name'] == 'nuttx_bth.bin')['Md5'] = hashlib.md5(data).hexdigest()
        members['OtaFileInfo.json'] = json.dumps(rows).encode()
        self.reject(members, 'semantics')

    def test_ap_change_even_with_correct_md5(self):
        members = self.members.copy()
        data = bytearray(members['nuttx_ap.bin'])
        data[-32] ^= 1
        members['nuttx_ap.bin'] = bytes(data)
        rows = json.loads(members['OtaFileInfo.json'])
        rows[2]['Md5'] = hashlib.md5(data).hexdigest()
        members['OtaFileInfo.json'] = json.dumps(rows).encode()
        self.reject(members, 'pinned R3 AP')

    def test_duplicate_manifest_names(self):
        self.reject(self.changed_manifest(lambda rows: rows.__setitem__(1, copy.deepcopy(rows[0]))),
                    'duplicate payload')

    def test_unsafe_name(self):
        self.reject(self.changed_manifest(lambda rows: rows[0].update(Name='../ap')), 'unsafe')

    def test_duplicate_json_keys(self):
        with self.assertRaisesRegex(ValueError, 'duplicate JSON'):
            gate.parse_manifest(b'[{"Name":"a","Name":"b"}]')

    def test_duplicate_zip(self):
        stream = io.BytesIO()
        with warnings.catch_warnings():
            warnings.simplefilter('ignore', UserWarning)
            with zipfile.ZipFile(stream, 'w') as z:
                z.writestr('x', b'1')
                z.writestr('x', b'2')
        with self.assertRaisesRegex(ValueError, 'duplicate ZIP'):
            gate.read_members(stream.getvalue(), {'x'})

    def test_extra_zip_member(self):
        stream = io.BytesIO()
        with zipfile.ZipFile(stream, 'w') as z:
            z.writestr('../x', b'1')
        with self.assertRaisesRegex(ValueError, 'unexpected or missing'):
            gate.read_members(stream.getvalue(), {'x'})


if __name__ == '__main__':
    unittest.main()
