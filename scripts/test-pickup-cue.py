#!/usr/bin/env python3
"""Synthetic checks for pickup-cue.py; no device result is implied."""

from __future__ import annotations

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

import numpy as np


SCRIPT = Path(__file__).with_name("pickup-cue.py")
spec = importlib.util.spec_from_file_location("pickup_cue", SCRIPT)
assert spec is not None and spec.loader is not None
cue = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = cue
spec.loader.exec_module(cue)


def wav_bytes(samples: np.ndarray) -> bytes:
    output = io.BytesIO()
    with wave.open(output, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(cue.SAMPLE_RATE)
        wav.writeframes(samples.astype("<i2").tobytes())
    return output.getvalue()


def read_wav(path: Path) -> np.ndarray:
    with wave.open(str(path), "rb") as wav:
        return np.frombuffer(wav.readframes(wav.getnframes()), dtype="<i2").copy()


class PickupCueTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.assets = self.directory / "assets"
        self.assets.mkdir()
        self.cues = []
        for number, frequency in ((1, 440), (2, 610)):
            time = np.arange(cue.SAMPLE_RATE * 2) / cue.SAMPLE_RATE
            speech = (6_500 * np.sin(2 * math.pi * frequency * time)).astype("<i2")
            source = self.directory / f"speech-{number}.wav"
            source.write_bytes(wav_bytes(speech))
            cue_path, _ = cue.make(source, f"pair-{number:02d}", self.assets)
            self.cues.append(read_wav(cue_path))
        self.plan = self.directory / "round-plan.json"
        self.plan.write_text(json.dumps({
            "schema_version": 1,
            "pilot_type": "single_movable_source",
            "geometry_id": "front-0deg-side-90deg-fixed-distance",
            "rounds": [{
                "round_id": "round-01", "export_zip": "round-01.zip", "sequence": "ABBA",
                "pairs": ["assets/pair-01.cue.json", "assets/pair-02.cue.json"],
                "playback_order": ["front", "side"],
            }],
        }), encoding="utf-8")

    def synthetic_recording(self, count: int = 8, wait_samples: int = 13_000) -> tuple[np.ndarray, list[int]]:
        rng = np.random.default_rng(91231)
        starts = []
        parts = [np.zeros(7_000, dtype=np.float64)]
        total = 7_000
        for play in range(count):
            material = self.cues[play // 4]
            starts.append(total)
            gain = 0.35 + play * 0.06
            signal = material.astype(np.float64) * gain
            echo = np.r_[np.zeros(95), signal[:-95] * 0.12]
            parts.append(signal + echo)
            total += len(material)
            parts.append(np.zeros(wait_samples, dtype=np.float64))
            total += wait_samples
        recording = np.concatenate(parts)
        recording += rng.normal(0, 28, len(recording))
        return np.clip(np.rint(recording), -32768, 32767).astype("<i2"), starts

    def write_zip(self, recording: np.ndarray, *, split_at: int | None = None) -> None:
        with zipfile.ZipFile(self.directory / "round-01.zip", "w") as archive:
            archive.writestr("session.json", json.dumps({"id": str(uuid.uuid4())}))
            if split_at is None:
                archive.writestr("audio-0000.wav", wav_bytes(recording))
            else:
                archive.writestr("audio-0000.wav", wav_bytes(recording[:split_at]))
                archive.writestr("audio-0001.wav", wav_bytes(recording[split_at:]))

    def test_make_and_locate_eight_play_candidate_without_auto_validating(self) -> None:
        recording, starts = self.synthetic_recording()
        self.write_zip(recording)
        output = self.directory / "candidate.json"
        report = self.directory / "report.json"
        cue.locate(self.plan, output, report)
        manifest = json.loads(output.read_text(encoding="utf-8"))
        blocks = manifest["rounds"][0]["blocks"]
        self.assertEqual([block["direction"] for block in blocks], ["around", "ahead", "ahead", "around"])
        self.assertTrue(all(block["valid"] is False for block in blocks))
        self.assertEqual([block["material_id"] for block in blocks], ["pair-01", "pair-01", "pair-02", "pair-02"])
        marks = json.loads(report.read_text(encoding="utf-8"))["rounds"][0]["markers"]
        self.assertEqual(
            manifest["rounds"][0]["archive_session_id"],
            json.loads(report.read_text(encoding="utf-8"))["rounds"][0]["archive_session_id"],
        )
        self.assertEqual(len(marks), 8)
        self.assertGreater(min(mark["correlation"] for mark in marks), cue.MIN_CORRELATION)
        for index, mark in enumerate(marks):
            self.assertLessEqual(abs(mark["onset_sample_in_continuous_audio"] - starts[index]), 4)
            window = mark["candidate_window"]
            self.assertEqual(window["wav"], "audio-0000.wav")
            self.assertEqual(
                window["start_sample"] - mark["onset_sample_in_continuous_audio"],
                cue.MARKER_SAMPLES + cue.GUARD_SAMPLES + cue.TRIM_SAMPLES,
            )
        analyzer = SCRIPT.with_name("analyze-pickup-angular-pilot.py")
        process = subprocess.run(
            [sys.executable, "-B", str(analyzer), str(output)],
            capture_output=True, text=True, check=False,
        )
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual(json.loads(process.stdout)["summary"]["raw_valid_blocks"], 0)
        for block in blocks:
            block["valid"] = True
            del block["invalid_reason"]
        reviewed = self.directory / "reviewed.json"
        reviewed.write_text(json.dumps(manifest), encoding="utf-8")
        process = subprocess.run(
            [sys.executable, "-B", str(analyzer), str(reviewed)],
            capture_output=True, text=True, check=False,
        )
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual(json.loads(process.stdout)["summary"]["raw_valid_pairs"], 2)

    def test_missing_marker_rejects_round(self) -> None:
        recording, _ = self.synthetic_recording(count=7)
        self.write_zip(recording)
        with self.assertRaisesRegex(cue.CueError, "found 7 acoustic markers, expected 8"):
            cue.locate(self.plan, self.directory / "candidate.json", self.directory / "report.json")

    def test_early_wav_split_is_possible_gap_and_rejected(self) -> None:
        recording, _ = self.synthetic_recording()
        self.write_zip(recording, split_at=cue.SAMPLE_RATE * 10)
        with self.assertRaisesRegex(cue.CueError, "rotated before 60 seconds"):
            cue.locate(self.plan, self.directory / "candidate.json", self.directory / "report.json")

    def test_normal_60_second_split_can_be_located(self) -> None:
        recording, starts = self.synthetic_recording(wait_samples=cue.SAMPLE_RATE * 6)
        self.assertGreater(len(recording), cue.NORMAL_SEGMENT_SAMPLES)
        self.write_zip(recording, split_at=cue.NORMAL_SEGMENT_SAMPLES)
        output = self.directory / "candidate.json"
        cue.locate(self.plan, output, self.directory / "report.json")
        blocks = json.loads(output.read_text(encoding="utf-8"))["rounds"][0]["blocks"]
        self.assertEqual(blocks[3]["windows"]["side"]["wav"], "audio-0001.wav")
        self.assertTrue(all(not block["valid"] for block in blocks))
        self.assertEqual(len(starts), 8)

    def test_bad_source_or_changed_cue_is_rejected(self) -> None:
        zero = self.directory / "silent.wav"
        zero.write_bytes(wav_bytes(np.zeros(cue.SAMPLE_RATE, dtype="<i2")))
        with self.assertRaisesRegex(cue.CueError, "silent"):
            cue.make(zero, "silent", self.assets)
        cue_path = self.assets / "pair-01.wav"
        cue_path.write_bytes(cue_path.read_bytes() + b"changed")
        recording, _ = self.synthetic_recording()
        self.write_zip(recording)
        with self.assertRaisesRegex(cue.CueError, "SHA-256 does not match"):
            cue.locate(self.plan, self.directory / "candidate.json", self.directory / "report.json")

    def test_cli_locate_writes_candidate_and_report(self) -> None:
        recording, _ = self.synthetic_recording()
        self.write_zip(recording)
        output = self.directory / "cli-candidate.json"
        process = subprocess.run(
            [sys.executable, "-B", str(SCRIPT), "locate", str(self.plan), "--output", str(output)],
            capture_output=True, text=True, check=False,
        )
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertTrue(output.exists())
        self.assertTrue((self.directory / "cli-candidate.locate-report.json").exists())

    def test_same_candidate_and_report_path_is_rejected(self) -> None:
        same = self.directory / "same.json"
        with self.assertRaisesRegex(cue.CueError, "different paths"):
            cue.locate(self.plan, same, same)
        self.assertFalse(same.exists())

    def test_too_many_zip_segments_are_rejected_before_reading_pcm(self) -> None:
        with zipfile.ZipFile(self.directory / "round-01.zip", "w") as archive:
            archive.writestr("session.json", json.dumps({"id": str(uuid.uuid4())}))
            for index in range(cue.MAX_SEGMENTS + 1):
                archive.writestr(f"audio-{index:04d}.wav", b"not a WAV")
        with self.assertRaisesRegex(cue.CueError, "5-minute WAV/segment safety limit"):
            cue.locate(self.plan, self.directory / "candidate.json", self.directory / "report.json")


if __name__ == "__main__":
    unittest.main()
