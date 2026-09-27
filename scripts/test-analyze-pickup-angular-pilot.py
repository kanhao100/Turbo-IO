#!/usr/bin/env python3
"""Synthetic ZIP/WAV tests for the solo-source angular-response pilot."""

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


SCRIPT = Path(__file__).with_name("analyze-pickup-angular-pilot.py")
SPEC = importlib.util.spec_from_file_location("pickup_angular_pilot", SCRIPT)
assert SPEC and SPEC.loader
pilot = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(pilot)


def wav_bytes(samples: list[int], *, rate: int = 16_000, channels: int = 1) -> bytes:
    output = io.BytesIO()
    with wave.open(output, "wb") as wav:
        wav.setnchannels(channels)
        wav.setsampwidth(2)
        wav.setframerate(rate)
        wav.writeframes(b"".join(value.to_bytes(2, "little", signed=True) for value in samples))
    return output.getvalue()


def one_round(sequence: str, index: int, *, ahead_side: int = 2_000) -> tuple[dict, bytes]:
    samples: list[int] = []
    blocks = []
    for block_index, letter in enumerate(sequence):
        direction = {"A": "around", "B": "ahead"}[letter]
        levels = {"front": 10_000, "side": 8_000 if direction == "around" else ahead_side}
        playback_order = ["front", "side"] if block_index % 2 == 0 else ["side", "front"]
        windows = {}
        for position in playback_order:
            start = len(samples)
            samples.extend([levels[position]] * 1600)
            windows[position] = {"wav": "audio-0000.wav", "start_sample": start, "end_sample": len(samples)}
        blocks.append({
            "direction": direction,
            "material_id": f"material-{index}-{block_index // 2}",
            "geometry_id": "front-0-side-90-radius-0p8m",
            "valid": True,
            "playback_order": playback_order,
            "windows": windows,
        })
    return {
        "round_id": f"round-{index:02d}",
        "export_zip": f"round-{index:02d}.zip",
        "sequence": sequence,
        "blocks": blocks,
    }, wav_bytes(samples)


class AngularPilotTests(unittest.TestCase):
    def setUp(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.directory = Path(temp.name)

    def write_zip(self, filename: str, wav: bytes, *, session_id: uuid.UUID) -> None:
        with zipfile.ZipFile(self.directory / filename, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("session.json", json.dumps({"id": str(session_id)}))
            archive.writestr("audio-0000.wav", wav)

    def fixture(self, sequences: list[str], *, ahead_side: int = 2_000) -> dict:
        manifest = {"schema_version": 1, "pilot_type": "single_movable_source", "rounds": []}
        for index, sequence in enumerate(sequences, start=1):
            round_item, wav = one_round(sequence, index, ahead_side=ahead_side)
            manifest["rounds"].append(round_item)
            self.write_zip(round_item["export_zip"], wav, session_id=uuid.UUID(int=index))
        return manifest

    def analyze(self, manifest: dict) -> dict:
        return pilot.analyze(manifest, manifest_dir=self.directory)

    def test_six_independent_rounds_positive_in_both_orders(self) -> None:
        result = self.analyze(self.fixture(["ABBA", "BAAB"] * 3))
        summary = result["summary"]
        self.assertEqual(summary["evidence_level"], "single_source_angular_response_pilot")
        self.assertEqual(summary["round_counts"], {"ABBA": 3, "BAAB": 3})
        self.assertEqual(summary["independent_valid_round_counts"], {"ABBA": 3, "BAAB": 3})
        self.assertEqual(summary["quantified_blocks"], 24)
        self.assertEqual(summary["quantified_pairs"], 12)
        self.assertEqual(summary["positive_delta_r_pairs"], 12)
        self.assertEqual(summary["replication"]["rounds_with_both_pairs_positive"], 6)
        self.assertEqual(summary["replication"]["by_sequence"]["ABBA"]["positive_delta_r_pairs"], 6)
        self.assertEqual(summary["replication"]["by_sequence"]["BAAB"]["positive_delta_r_pairs"], 6)
        self.assertAlmostEqual(summary["median_delta_r_db"], 20 * math.log10(4), places=6)
        self.assertAlmostEqual(summary["median_delta_f_db"], 0, places=6)
        self.assertIsNone(summary["device_effect_confirmed"])
        self.assertNotIn("full_design_evidence", summary)
        self.assertNotIn("quantitative_conditions", summary)
        self.assertNotIn("mixed", result["blocks"][0]["windows"])
        self.assertEqual(result["pairs"][0]["block_numbers"], [1, 2])
        self.assertEqual(result["pairs"][1]["block_numbers"], [3, 4])
        self.assertEqual(result["blocks"][1]["playback_order"], ["side", "front"])
        self.assertIn("no mixed-source SNR", summary["scope"])

    def test_reversed_effect_is_described_without_pass_fail_label(self) -> None:
        summary = self.analyze(self.fixture(["ABBA", "BAAB"] * 3, ahead_side=16_000))["summary"]
        self.assertLess(summary["median_delta_r_db"], 0)
        self.assertEqual(summary["positive_delta_r_pairs"], 0)
        self.assertEqual(summary["replication"]["rounds_with_both_pairs_positive"], 0)
        self.assertNotIn("passed", summary)

    def test_partial_one_round_is_still_pilot_only(self) -> None:
        summary = self.analyze(self.fixture(["ABBA"]))["summary"]
        self.assertEqual(summary["quantified_pairs"], 2)
        self.assertEqual(summary["evidence_level"], "single_source_angular_response_pilot")
        self.assertIsNone(summary["device_effect_confirmed"])

    def test_wrong_schema_direction_and_material_are_rejected(self) -> None:
        manifest = self.fixture(["ABBA"])
        changed = copy.deepcopy(manifest)
        changed["pilot_type"] = "two_sources"
        with self.assertRaisesRegex(pilot.AnalysisError, "single_movable_source"):
            self.analyze(changed)
        changed = copy.deepcopy(manifest)
        changed["rounds"][0]["blocks"][1]["direction"] = "around"
        with self.assertRaisesRegex(pilot.AnalysisError, "expected 'ahead'"):
            self.analyze(changed)
        changed = copy.deepcopy(manifest)
        changed["rounds"][0]["blocks"][1]["material_id"] = "different"
        with self.assertRaisesRegex(pilot.AnalysisError, "same material_id"):
            self.analyze(changed)

    def test_bad_wav_format_bounds_overlap_and_silence_are_rejected(self) -> None:
        manifest = self.fixture(["ABBA"])
        round_item, good_wav = one_round("ABBA", 1)
        del round_item
        samples = [1000] * 12_800
        for broken in (wav_bytes(samples, rate=8_000), wav_bytes(samples, channels=2)):
            self.write_zip("round-01.zip", broken, session_id=uuid.UUID(int=1))
            with self.assertRaisesRegex(pilot.AnalysisError, "expected 16000 Hz, mono, PCM16"):
                self.analyze(manifest)
        self.write_zip("round-01.zip", good_wav, session_id=uuid.UUID(int=1))
        changed = copy.deepcopy(manifest)
        changed["rounds"][0]["blocks"][0]["windows"]["front"]["end_sample"] = 10**9
        with self.assertRaisesRegex(pilot.AnalysisError, "exceeds WAV length"):
            self.analyze(changed)
        changed = copy.deepcopy(manifest)
        changed["rounds"][0]["blocks"][0]["windows"]["side"]["start_sample"] = 800
        changed["rounds"][0]["blocks"][0]["windows"]["side"]["end_sample"] = 2400
        with self.assertRaisesRegex(pilot.AnalysisError, "overlaps .* across windows"):
            self.analyze(changed)
        self.write_zip("round-01.zip", wav_bytes([0] * 12_800), session_id=uuid.UUID(int=1))
        with self.assertRaisesRegex(pilot.AnalysisError, "all-zero window"):
            self.analyze(manifest)

    def test_playback_order_and_equal_windows_are_enforced(self) -> None:
        manifest = self.fixture(["ABBA"])
        changed = copy.deepcopy(manifest)
        changed["rounds"][0]["blocks"][1]["playback_order"] = ["front", "side"]
        with self.assertRaisesRegex(pilot.AnalysisError, "contradict playback_order"):
            self.analyze(changed)
        changed = copy.deepcopy(manifest)
        changed["rounds"][0]["blocks"][0]["windows"]["front"]["end_sample"] -= 1
        with self.assertRaisesRegex(pilot.AnalysisError, "equal sample counts"):
            self.analyze(changed)
        changed = copy.deepcopy(manifest)
        changed["rounds"][0]["blocks"][1]["windows"]["side"]["end_sample"] -= 1
        changed["rounds"][0]["blocks"][1]["windows"]["front"]["end_sample"] -= 1
        with self.assertRaisesRegex(pilot.AnalysisError, "paired front windows"):
            self.analyze(changed)

    def test_whole_blocks_must_follow_recording_order(self) -> None:
        manifest = self.fixture(["ABBA"])
        blocks = manifest["rounds"][0]["blocks"]
        for field in ("windows", "playback_order"):
            blocks[0][field], blocks[1][field] = blocks[1][field], blocks[0][field]
        with self.assertRaisesRegex(pilot.AnalysisError, "blocks must follow playback order"):
            self.analyze(manifest)

    def test_invalid_review_pending_block_keeps_round_visible_but_excluded(self) -> None:
        manifest = self.fixture(["ABBA", "BAAB"])
        block = manifest["rounds"][0]["blocks"][0]
        block["valid"] = False
        block["invalid_reason"] = "pending manual review"
        result = self.analyze(manifest)
        self.assertEqual(result["summary"]["raw_valid_blocks"], 7)
        self.assertEqual(result["summary"]["raw_valid_pairs"], 3)
        self.assertEqual(result["summary"]["quantified_blocks"], 4)
        self.assertEqual(result["summary"]["quantified_pairs"], 2)
        self.assertFalse(result["rounds"][0]["independent_session"])
        self.assertEqual(result["blocks"][0]["invalid_reason"], "pending manual review")

    def test_missing_explicit_manual_review_flag_is_rejected(self) -> None:
        manifest = self.fixture(["ABBA"])
        del manifest["rounds"][0]["blocks"][0]["valid"]
        with self.assertRaisesRegex(pilot.AnalysisError, "explicit boolean required"):
            self.analyze(manifest)
        manifest["rounds"][0]["blocks"][0]["valid"] = False
        manifest["rounds"][0]["blocks"][0]["invalid_reason"] = "pending manual review"
        result = self.analyze(manifest)
        self.assertEqual(result["summary"]["quantified_pairs"], 0)
        self.assertFalse(result["blocks"][0]["valid"])

    def test_valid_true_with_pending_review_reason_is_rejected(self) -> None:
        manifest = self.fixture(["ABBA"])
        manifest["rounds"][0]["blocks"][0]["invalid_reason"] = "pending manual review"
        with self.assertRaisesRegex(pilot.AnalysisError, "valid=true conflicts with invalid_reason"):
            self.analyze(manifest)

    def test_copied_session_id_and_zip_are_not_independent(self) -> None:
        manifest = self.fixture(["ABBA", "BAAB", "ABBA"])
        _, wav = one_round("BAAB", 2)
        self.write_zip("round-02.zip", wav, session_id=uuid.UUID(int=1))
        result = self.analyze(manifest)
        self.assertEqual(result["summary"]["independent_valid_round_counts"], {"ABBA": 1, "BAAB": 0})
        self.assertEqual(result["summary"]["quantified_pairs"], 2)
        # Two nominal rounds sharing one ZIP also cannot be counted independently.
        manifest = self.fixture(["ABBA", "ABBA"])
        manifest["rounds"][1]["export_zip"] = manifest["rounds"][0]["export_zip"]
        for block in manifest["rounds"][1]["blocks"]:
            for window in block["windows"].values():
                window["start_sample"] += 12_800
                window["end_sample"] += 12_800
        _, first_wav = one_round("ABBA", 1)
        _, second_wav = one_round("ABBA", 2)
        with wave.open(io.BytesIO(first_wav), "rb") as first, wave.open(io.BytesIO(second_wav), "rb") as second:
            first_pcm = first.readframes(12_800)
            second_pcm = second.readframes(12_800)
            combined_samples = [int.from_bytes(first_pcm[index:index + 2], "little", signed=True) for index in range(0, len(first_pcm), 2)]
            combined_samples.extend(int.from_bytes(second_pcm[index:index + 2], "little", signed=True) for index in range(0, len(second_pcm), 2))
        self.write_zip("round-01.zip", wav_bytes(combined_samples), session_id=uuid.UUID(int=1))
        result = self.analyze(manifest)
        self.assertEqual(result["summary"]["quantified_pairs"], 0)

    def test_geometry_and_reused_material_are_rejected(self) -> None:
        manifest = self.fixture(["ABBA"])
        changed = copy.deepcopy(manifest)
        changed["rounds"][0]["blocks"][2]["geometry_id"] = "left-side"
        changed["rounds"][0]["blocks"][3]["geometry_id"] = "left-side"
        with self.assertRaisesRegex(pilot.AnalysisError, "one geometry_id"):
            self.analyze(changed)
        changed = copy.deepcopy(manifest)
        for block in changed["rounds"][0]["blocks"][2:]:
            block["material_id"] = changed["rounds"][0]["blocks"][0]["material_id"]
        with self.assertRaisesRegex(pilot.AnalysisError, "is reused"):
            self.analyze(changed)

    def test_optional_archive_session_id_must_match(self) -> None:
        manifest = self.fixture(["ABBA"])
        manifest["rounds"][0]["archive_session_id"] = str(uuid.UUID(int=1))
        self.assertEqual(self.analyze(manifest)["rounds"][0]["archive_session_id"], str(uuid.UUID(int=1)))
        manifest["rounds"][0]["archive_session_id"] = str(uuid.UUID(int=2))
        with self.assertRaisesRegex(pilot.AnalysisError, "does not match ZIP session.json.id"):
            self.analyze(manifest)

    def test_cli_example_output_and_error(self) -> None:
        example = subprocess.run([sys.executable, "-B", str(SCRIPT), "--example-manifest"], text=True, capture_output=True, check=False)
        self.assertEqual(example.returncode, 0, example.stderr)
        parsed_example = json.loads(example.stdout)
        self.assertEqual(parsed_example["pilot_type"], "single_movable_source")
        self.assertTrue(all(block["valid"] is False for block in parsed_example["rounds"][0]["blocks"]))
        manifest = self.fixture(["ABBA"])
        manifest_path = self.directory / "manifest.json"
        output_path = self.directory / "result.json"
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
        completed = subprocess.run([sys.executable, "-B", str(SCRIPT), str(manifest_path), "--output", str(output_path)], text=True, capture_output=True, check=False)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(json.loads(output_path.read_text(encoding="utf-8"))["summary"]["quantified_pairs"], 2)
        manifest_path.write_text("{}", encoding="utf-8")
        completed = subprocess.run([sys.executable, "-B", str(SCRIPT), str(manifest_path)], text=True, capture_output=True, check=False)
        self.assertEqual(completed.returncode, 2)
        self.assertIn("analysis failed", completed.stderr)


if __name__ == "__main__":
    unittest.main()
