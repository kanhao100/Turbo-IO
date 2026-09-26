#!/usr/bin/env python3
"""Synthetic, private-data-free checks for analyze-pickup-direction.py."""

from __future__ import annotations

import copy
import importlib.util
import io
import json
import math
import subprocess
import sys
import tempfile
import unittest
import uuid
import wave
import zipfile
from pathlib import Path


SCRIPT = Path(__file__).with_name("analyze-pickup-direction.py")
SPEC = importlib.util.spec_from_file_location("pickup_direction_analysis", SCRIPT)
assert SPEC and SPEC.loader
analysis = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(analysis)


def wav_bytes(samples: list[int], *, rate: int = 16_000, channels: int = 1, sample_width: int = 2) -> bytes:
    output = io.BytesIO()
    with wave.open(output, "wb") as wav:
        wav.setnchannels(channels)
        wav.setsampwidth(sample_width)
        wav.setframerate(rate)
        if sample_width == 2:
            raw = b"".join(sample.to_bytes(2, "little", signed=True) for sample in samples)
        else:
            raw = bytes(samples)
        wav.writeframes(raw)
    return output.getvalue()


def fixture(round_sequences: list[str], *, metric: str = "cer", ahead_interferer: int = 2_000) -> tuple[dict, bytes]:
    reference, around_recognized = (
        ("今天阳光很好", "今天很好") if metric == "cer"
        else ("Please open the window", "please window")
    )
    manifest = {"schema_version": 1, "text_metric": metric, "rounds": []}
    samples: list[int] = []
    segment_size = 1600
    for round_index, sequence in enumerate(round_sequences):
        round_item = {"round_id": f"round-{round_index + 1:02d}", "sequence": sequence, "blocks": []}
        for block_index, letter in enumerate(sequence):
            direction = {"A": "around", "B": "ahead"}[letter]
            target_level = 10_000
            interferer_level = 8_000 if direction == "around" else ahead_interferer
            windows = {}
            for kind, level in (("target", target_level), ("interferer", interferer_level), ("mixed", 5_000)):
                start = len(samples)
                samples.extend([level] * segment_size)
                windows[kind] = {"wav": "audio-0000.wav", "start_sample": start, "end_sample": len(samples)}
            round_item["blocks"].append({
                "direction": direction,
                "material_id": f"material-{round_index}-{block_index // 2}",
                "geometry_id": "target-0-interferer-90",
                "windows": windows,
                "reference": reference,
                "recognized": around_recognized if direction == "around" else reference,
            })
        manifest["rounds"].append(round_item)
    return manifest, wav_bytes(samples)


class PickupDirectionAnalysisTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.zip_path = self.directory / "session.zip"

    def write_zip(self, wav: bytes, *, path: Path | None = None, session_id: uuid.UUID | None = None) -> Path:
        path = path or self.zip_path
        session_id = session_id or uuid.UUID(int=1)
        with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("session.json", json.dumps({"id": str(session_id)}))
            archive.writestr("audio-0000.wav", wav)
        return path

    def run_analysis(self, manifest: dict, wav: bytes) -> dict:
        self.write_zip(wav)
        return analysis.analyze(self.zip_path, manifest)

    def multi_zip_fixture(self, sequences: list[str], *, ahead_interferer: int = 2_000) -> dict:
        manifest = {"schema_version": 1, "text_metric": "cer", "rounds": []}
        for index, sequence in enumerate(sequences):
            one, wav = fixture([sequence], ahead_interferer=ahead_interferer)
            round_item = one["rounds"][0]
            round_item["round_id"] = f"round-{index + 1:02d}"
            round_item["export_zip"] = f"round-{index + 1:02d}.zip"
            for block_index, block in enumerate(round_item["blocks"]):
                block["material_id"] = f"material-{index}-{block_index // 2}"
            self.write_zip(wav, path=self.directory / round_item["export_zip"], session_id=uuid.UUID(int=index + 1))
            manifest["rounds"].append(round_item)
        return manifest

    def test_complete_six_round_design_and_positive_thresholds(self) -> None:
        manifest = self.multi_zip_fixture(["ABBA", "BAAB"] * 3)
        result = analysis.analyze(None, manifest, manifest_dir=self.directory)
        summary = result["summary"]
        self.assertEqual(summary["round_counts"], {"ABBA": 3, "BAAB": 3})
        self.assertEqual(summary["valid_round_counts"], {"ABBA": 3, "BAAB": 3})
        self.assertEqual(summary["independent_valid_round_counts"], {"ABBA": 3, "BAAB": 3})
        self.assertEqual(summary["valid_blocks"], 24)
        self.assertEqual(summary["valid_pairs"], 12)
        self.assertTrue(summary["full_design_evidence"])
        self.assertEqual(summary["positive_delta_r_pairs"], 12)
        self.assertAlmostEqual(summary["median_delta_r_db"], 20 * math.log10(4), places=6)
        self.assertAlmostEqual(summary["median_delta_f_db"], 0, places=6)
        self.assertEqual(summary["pooled_mixed_text"]["around"]["error_rate"], 2 / 6)
        self.assertEqual(summary["pooled_mixed_text"]["ahead"]["error_rate"], 0)
        self.assertTrue(all(value["met"] for value in summary["quantitative_conditions"].values()))
        self.assertIsNone(summary["device_effect_confirmed"])
        required = " ".join(summary["external_checks_required"])
        self.assertIn("Turbo-IO application-layer type 10", required)
        self.assertIn("SDK send and asynchronous failure", required)
        self.assertIn("uninterrupted type 4 audio", required)
        self.assertIn("acoustic effect on the target glasses", required)
        self.assertNotIn("official Android app", required)
        self.assertIn("official Android app", " ".join(summary["optional_cross_checks"]))
        self.assertEqual(result["pairs"][0]["block_numbers"], [1, 2])
        self.assertEqual(result["pairs"][1]["block_numbers"], [3, 4])
        self.assertEqual(result["blocks"][0]["text"]["deletions"], 2)
        self.assertIn("no source separation", result["method"]["mixed"])

    def test_partial_design_is_preanalysis_even_with_good_numbers(self) -> None:
        manifest, wav = fixture(["ABBA"])
        summary = self.run_analysis(manifest, wav)["summary"]
        self.assertEqual(summary["valid_blocks"], 4)
        self.assertEqual(summary["valid_pairs"], 2)
        self.assertFalse(summary["full_design_evidence"])
        self.assertEqual(summary["evidence_level"], "preanalysis_insufficient")
        self.assertTrue(all(condition["met"] is None for condition in summary["quantitative_conditions"].values()))

    def test_reverse_direction_fails_acoustic_threshold(self) -> None:
        manifest = self.multi_zip_fixture(["ABBA", "BAAB"] * 3, ahead_interferer=16_000)
        summary = analysis.analyze(None, manifest, manifest_dir=self.directory)["summary"]
        self.assertEqual(summary["positive_delta_r_pairs"], 0)
        self.assertLess(summary["median_delta_r_db"], 0)
        self.assertFalse(summary["quantitative_conditions"]["median_delta_r_ge_3_db"]["met"])
        self.assertFalse(summary["quantitative_conditions"]["positive_delta_r_ge_10_of_12"]["met"])

    def test_english_wer_and_edit_components(self) -> None:
        manifest, wav = fixture(["BAAB"], metric="wer")
        result = self.run_analysis(manifest, wav)
        around = next(block for block in result["blocks"] if block["direction"] == "around")
        self.assertEqual(around["text"]["reference_units"], 4)
        self.assertEqual(around["text"]["deletions"], 2)
        self.assertEqual(around["text"]["error_rate"], 0.5)
        self.assertEqual(analysis.normalize_units("DON'T, STOP!", "wer"), ["don", "t", "stop"])
        self.assertEqual(analysis.normalize_units("你好， 2026!", "cer"), list("你好2026"))

    def test_invalid_wav_format_and_window_bounds(self) -> None:
        manifest, wav = fixture(["ABBA"])
        samples = [1000] * (len(wav) // 2)
        for broken in (wav_bytes(samples, rate=8_000), wav_bytes(samples, channels=2), wav_bytes([128] * len(samples), sample_width=1)):
            with self.subTest(format=broken[20:36]):
                with self.assertRaisesRegex(analysis.AnalysisError, "expected 16000 Hz, mono, PCM16"):
                    self.run_analysis(manifest, broken)
        too_long = copy.deepcopy(manifest)
        too_long["rounds"][0]["blocks"][0]["windows"]["target"]["end_sample"] = 10**9
        with self.assertRaisesRegex(analysis.AnalysisError, "exceeds WAV length"):
            self.run_analysis(too_long, wav)
        reversed_window = copy.deepcopy(manifest)
        reversed_window["rounds"][0]["blocks"][0]["windows"]["target"]["end_sample"] = 0
        with self.assertRaisesRegex(analysis.AnalysisError, "start_sample < end_sample"):
            self.run_analysis(reversed_window, wav)

    def test_pair_material_and_sample_count_are_enforced(self) -> None:
        manifest, wav = fixture(["ABBA"])
        changed = copy.deepcopy(manifest)
        changed["rounds"][0]["blocks"][1]["material_id"] = "different"
        with self.assertRaisesRegex(analysis.AnalysisError, "same material_id"):
            self.run_analysis(changed, wav)
        changed = copy.deepcopy(manifest)
        changed["rounds"][0]["blocks"][1]["windows"]["target"]["end_sample"] -= 1
        changed["rounds"][0]["blocks"][1]["windows"]["interferer"]["end_sample"] -= 1
        with self.assertRaisesRegex(analysis.AnalysisError, "paired target windows"):
            self.run_analysis(changed, wav)
        changed = copy.deepcopy(manifest)
        changed["rounds"][0]["blocks"][1]["reference"] = "另一个素材"
        with self.assertRaisesRegex(analysis.AnalysisError, "paired reference texts"):
            self.run_analysis(changed, wav)
        changed = copy.deepcopy(manifest)
        for block in changed["rounds"][0]["blocks"][2:]:
            block["material_id"] = "material-0-0"
        with self.assertRaisesRegex(analysis.AnalysisError, "is reused"):
            self.run_analysis(changed, wav)

    def test_two_zip_rounds_isolate_identical_wav_names(self) -> None:
        manifest = self.multi_zip_fixture(["ABBA", "BAAB"])
        result = analysis.analyze(None, manifest, manifest_dir=self.directory)
        self.assertEqual(result["summary"]["valid_round_counts"], {"ABBA": 1, "BAAB": 1})
        self.assertEqual(result["summary"]["independent_valid_round_counts"], {"ABBA": 1, "BAAB": 1})
        self.assertEqual(result["summary"]["valid_pairs"], 4)
        self.assertEqual(result["blocks"][0]["windows"]["target"]["wav"], "audio-0000.wav")
        self.assertEqual(result["blocks"][4]["windows"]["target"]["wav"], "audio-0000.wav")

    def test_copied_session_id_cannot_count_as_independent_round(self) -> None:
        manifest = self.multi_zip_fixture(["ABBA", "BAAB"] * 3)
        copied_path = self.directory / manifest["rounds"][1]["export_zip"]
        _, wav = fixture(["BAAB"])
        self.write_zip(wav, path=copied_path, session_id=uuid.UUID(int=1))
        summary = analysis.analyze(None, manifest, manifest_dir=self.directory)["summary"]
        self.assertEqual(summary["valid_round_counts"], {"ABBA": 3, "BAAB": 3})
        self.assertEqual(summary["independent_valid_round_counts"], {"ABBA": 2, "BAAB": 2})
        self.assertFalse(summary["full_design_evidence"])

    def test_optional_archive_session_id_must_match_zip(self) -> None:
        manifest = self.multi_zip_fixture(["ABBA"])
        manifest["rounds"][0]["archive_session_id"] = str(uuid.UUID(int=1))
        self.assertEqual(analysis.analyze(None, manifest, manifest_dir=self.directory)["rounds"][0]["archive_session_id"], str(uuid.UUID(int=1)))
        manifest["rounds"][0]["archive_session_id"] = str(uuid.UUID(int=2))
        with self.assertRaisesRegex(analysis.AnalysisError, "does not match ZIP session.json.id"):
            analysis.analyze(None, manifest, manifest_dir=self.directory)

    def test_full_design_requires_three_complete_rounds_of_each_order(self) -> None:
        manifest = self.multi_zip_fixture(["ABBA"] * 6 + ["BAAB"] * 3)
        for round_item in manifest["rounds"][6:]:
            round_item["blocks"][0] = {
                "direction": "ahead", "material_id": round_item["blocks"][1]["material_id"],
                "geometry_id": "target-0-interferer-90", "valid": False,
                "invalid_reason": "audio gap",
            }
        summary = analysis.analyze(None, manifest, manifest_dir=self.directory)["summary"]
        self.assertEqual(summary["valid_round_counts"], {"ABBA": 6, "BAAB": 0})
        self.assertGreaterEqual(summary["valid_blocks"], 24)
        self.assertGreaterEqual(summary["valid_pairs"], 12)
        self.assertFalse(summary["full_design_evidence"])

    def test_mixed_geometry_and_reused_windows_are_rejected(self) -> None:
        manifest, wav = fixture(["ABBA"])
        changed = copy.deepcopy(manifest)
        changed["rounds"][0]["blocks"][2]["geometry_id"] = "target-0-interferer-180"
        changed["rounds"][0]["blocks"][3]["geometry_id"] = "target-0-interferer-180"
        with self.assertRaisesRegex(analysis.AnalysisError, "one geometry_id"):
            self.run_analysis(changed, wav)
        changed = copy.deepcopy(manifest)
        changed["rounds"][0]["blocks"][1]["windows"] = changed["rounds"][0]["blocks"][0]["windows"]
        with self.assertRaisesRegex(analysis.AnalysisError, "overlaps .* across blocks"):
            self.run_analysis(changed, wav)

    def test_order_invalid_block_overlap_and_silence(self) -> None:
        manifest, wav = fixture(["ABBA"])
        changed = copy.deepcopy(manifest)
        changed["rounds"][0]["blocks"][1]["direction"] = "around"
        with self.assertRaisesRegex(analysis.AnalysisError, "expected 'ahead'"):
            self.run_analysis(changed, wav)
        changed = copy.deepcopy(manifest)
        changed["rounds"][0]["blocks"][1] = {
            "direction": "ahead", "material_id": "material-0-0", "geometry_id": "target-0-interferer-90",
            "valid": False, "invalid_reason": "audio gap during playback",
        }
        result = self.run_analysis(changed, wav)
        self.assertEqual(result["summary"]["valid_blocks"], 3)
        self.assertEqual(result["summary"]["valid_pairs"], 1)
        changed = copy.deepcopy(manifest)
        changed["rounds"][0]["blocks"][0]["windows"]["interferer"] = changed["rounds"][0]["blocks"][0]["windows"]["target"]
        with self.assertRaisesRegex(analysis.AnalysisError, "windows overlap"):
            self.run_analysis(changed, wav)
        with self.assertRaisesRegex(analysis.AnalysisError, "all-zero window"):
            self.run_analysis(manifest, wav_bytes([0] * (len(wav) // 2)))

    def test_wav_decompression_limit(self) -> None:
        manifest, _ = fixture(["ABBA"])
        self.write_zip(b"x" * (analysis.MAX_WAV_BYTES + 1))
        with self.assertRaisesRegex(analysis.AnalysisError, "exceeds 9600044 byte"):
            analysis.analyze(self.zip_path, manifest)

    def test_cli_writes_json_and_reports_errors(self) -> None:
        manifest, wav = fixture(["ABBA"])
        self.write_zip(wav)
        manifest_path = self.directory / "manifest.json"
        output_path = self.directory / "result.json"
        manifest_path.write_text(json.dumps(manifest, ensure_ascii=False), encoding="utf-8")
        process = subprocess.run(
            [sys.executable, str(SCRIPT), str(self.zip_path), str(manifest_path), "--output", str(output_path)],
            capture_output=True, text=True, check=False,
        )
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual(json.loads(output_path.read_text(encoding="utf-8"))["summary"]["valid_pairs"], 2)
        manifest["rounds"][0]["blocks"][0]["direction"] = "ahead"
        manifest_path.write_text(json.dumps(manifest, ensure_ascii=False), encoding="utf-8")
        process = subprocess.run(
            [sys.executable, str(SCRIPT), str(self.zip_path), str(manifest_path)],
            capture_output=True, text=True, check=False,
        )
        self.assertEqual(process.returncode, 2)
        self.assertIn("expected 'around'", process.stderr)

    def test_cli_multi_zip_relative_paths_and_text_limit(self) -> None:
        manifest = self.multi_zip_fixture(["ABBA", "BAAB"])
        manifest_path = self.directory / "manifest.json"
        manifest_path.write_text(json.dumps(manifest, ensure_ascii=False), encoding="utf-8")
        process = subprocess.run(
            [sys.executable, str(SCRIPT), str(manifest_path)],
            capture_output=True, text=True, check=False,
        )
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual(json.loads(process.stdout)["summary"]["valid_pairs"], 4)
        manifest["rounds"][0]["blocks"][0]["reference"] = "字" * (analysis.MAX_TEXT_UNITS + 1)
        with self.assertRaisesRegex(analysis.AnalysisError, "at most 2000 units"):
            analysis.analyze(None, manifest, manifest_dir=self.directory)


if __name__ == "__main__":
    unittest.main()
