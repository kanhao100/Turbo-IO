#!/usr/bin/env python3
"""Prepare and locate a single movable-source pickup-direction experiment.

One spare phone plays a marked mono WAV from a fixed front or side position.
The glasses/iPhone session records eight plays in ABBA or BAAB order: each of
four direction blocks contains front and side, in the declared order. This is
an acoustic pilot, not the simultaneous two-source/CER experiment.

Examples:
  python -B scripts/pickup-cue.py make --source speech.wav --material-id pair-01 --out-dir pickup-assets
  python -B scripts/pickup-cue.py --example-round-plan
  python -B scripts/pickup-cue.py locate pickup-round-plan.json --output pickup-candidates.json

The locator uses NumPy for FFT correlation. It proposes sample windows only;
it cannot observe where the phone stood, whether a direction took effect, or
whether type 4 audio was continuous. Every emitted block remains invalid until
an operator checks those facts and the audible marker alignment.
"""

from __future__ import annotations

import argparse
import array
import bisect
import hashlib
import io
import json
import math
import os
import re
import sys
import uuid
import wave
import zipfile
from pathlib import Path
from typing import Any


SAMPLE_RATE = 16_000
MARKER_SAMPLES = 5_760  # 360 ms chirp, 1.1 -> 3.1 kHz
GUARD_SAMPLES = 7_200  # 450 ms from marker end to speech start
TAIL_SAMPLES = 6_400  # 400 ms after speech
TRIM_SAMPLES = 3_200  # predeclared 200 ms off each speech end
NORMAL_SEGMENT_SAMPLES = 60 * SAMPLE_RATE
MAX_ZIP_WAV_BYTES = NORMAL_SEGMENT_SAMPLES * 2 + 44
MAX_TOTAL_SAMPLES = 5 * 60 * SAMPLE_RATE
MAX_SEGMENTS = 5
MIN_CORRELATION = 0.12
MIN_MARKER_SEPARATION_SAMPLES = SAMPLE_RATE * 3 // 4
WAV_NAME = re.compile(r"audio-([0-9]{4})\.wav\Z")
MATERIAL_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]{0,63}\Z")
LETTERS = {"A": "around", "B": "ahead"}


class CueError(ValueError):
    pass


def marker_pcm() -> array.array[int]:
    """Fixed, tapered chirp; identical samples are used by make and locate."""
    result = array.array("h")
    duration = MARKER_SAMPLES / SAMPLE_RATE
    fade = 320  # 20 ms avoids hard clicks
    for index in range(MARKER_SAMPLES):
        time = index / SAMPLE_RATE
        phase = 2 * math.pi * (1_100 * time + (3_100 - 1_100) * time * time / (2 * duration))
        envelope = min(1.0, index / fade, (MARKER_SAMPLES - 1 - index) / fade)
        result.append(round(0.22 * 32767 * max(0.0, envelope) * math.sin(phase)))
    return result


def little_endian_bytes(samples: array.array[int]) -> bytes:
    if sys.byteorder == "little":
        return samples.tobytes()
    copy = array.array("h", samples)
    copy.byteswap()
    return copy.tobytes()


def read_source(path: Path) -> array.array[int]:
    try:
        with wave.open(str(path), "rb") as source:
            properties = (source.getframerate(), source.getnchannels(), source.getsampwidth(), source.getcomptype())
            if properties != (SAMPLE_RATE, 1, 2, "NONE"):
                raise CueError(f"source must be uncompressed 16 kHz mono PCM16, got {properties}")
            count = source.getnframes()
            if not SAMPLE_RATE <= count <= 8 * SAMPLE_RATE:
                raise CueError("source duration must be between 1 and 8 seconds")
            contents = source.readframes(count)
    except (OSError, wave.Error, EOFError) as exc:
        raise CueError(f"cannot read source WAV: {exc}") from exc
    if len(contents) != count * 2:
        raise CueError("source WAV is truncated")
    samples = array.array("h")
    samples.frombytes(contents)
    if sys.byteorder != "little":
        samples.byteswap()
    if not any(samples):
        raise CueError("source WAV is silent")
    return samples


def write_wav(path: Path, samples: array.array[int]) -> None:
    with wave.open(str(path), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(SAMPLE_RATE)
        output.writeframes(little_endian_bytes(samples))


def make(source: Path, material_id: str, out_dir: Path) -> tuple[Path, Path]:
    if not MATERIAL_ID.fullmatch(material_id):
        raise CueError("material-id must contain only letters, digits, underscore or hyphen")
    speech = read_source(source)
    out_dir.mkdir(parents=True, exist_ok=True)
    cue_path = out_dir / f"{material_id}.wav"
    descriptor_path = out_dir / f"{material_id}.cue.json"
    if cue_path.exists() or descriptor_path.exists():
        raise CueError("cue or descriptor already exists; choose a new material-id")
    cue = marker_pcm()
    cue.extend(array.array("h", [0]) * GUARD_SAMPLES)
    cue.extend(speech)
    cue.extend(array.array("h", [0]) * TAIL_SAMPLES)
    write_wav(cue_path, cue)
    descriptor = {
        "schema_version": 1,
        "cue_kind": "single_movable_source_chirp_v1",
        "material_id": material_id,
        "cue_file": cue_path.name,
        "cue_sha256": hashlib.sha256(cue_path.read_bytes()).hexdigest(),
        "source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
        "sample_rate": SAMPLE_RATE,
        "marker_samples": MARKER_SAMPLES,
        "guard_samples": GUARD_SAMPLES,
        "source_samples": len(speech),
        "tail_samples": TAIL_SAMPLES,
        "trim_samples": TRIM_SAMPLES,
        "analysis_start_offset_samples": MARKER_SAMPLES + GUARD_SAMPLES + TRIM_SAMPLES,
        "analysis_end_offset_samples": MARKER_SAMPLES + GUARD_SAMPLES + len(speech) - TRIM_SAMPLES,
        "note": "One marked mono play. Move the same phone between fixed front and side locations; keep volume fixed.",
    }
    descriptor_path.write_text(json.dumps(descriptor, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return cue_path, descriptor_path


def read_descriptor(path: Path) -> dict[str, Any]:
    try:
        descriptor = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise CueError(f"cannot read cue descriptor {path}: {exc}") from exc
    if not isinstance(descriptor, dict) or descriptor.get("schema_version") != 1 or descriptor.get("cue_kind") != "single_movable_source_chirp_v1":
        raise CueError(f"{path}: expected single_movable_source_chirp_v1 descriptor")
    material_id = descriptor.get("material_id")
    if not isinstance(material_id, str) or not MATERIAL_ID.fullmatch(material_id):
        raise CueError(f"{path}: invalid material_id")
    for hash_name in ("cue_sha256", "source_sha256"):
        if not isinstance(descriptor.get(hash_name), str) or not re.fullmatch(r"[0-9a-f]{64}", descriptor[hash_name]):
            raise CueError(f"{path}: invalid {hash_name}")
    for key, expected in (
        ("sample_rate", SAMPLE_RATE), ("marker_samples", MARKER_SAMPLES),
        ("guard_samples", GUARD_SAMPLES), ("tail_samples", TAIL_SAMPLES),
        ("trim_samples", TRIM_SAMPLES),
    ):
        if type(descriptor.get(key)) is not int or descriptor[key] != expected:
            raise CueError(f"{path}: {key} is inconsistent with this locator version")
    count = descriptor.get("source_samples")
    if type(count) is not int or not SAMPLE_RATE <= count <= 8 * SAMPLE_RATE:
        raise CueError(f"{path}: invalid source_samples")
    cue_file = descriptor.get("cue_file")
    if cue_file != f"{material_id}.wav":
        raise CueError(f"{path}: cue_file must be {material_id}.wav")
    cue_path = path.parent / cue_file
    try:
        cue_bytes = cue_path.read_bytes()
        actual_hash = hashlib.sha256(cue_bytes).hexdigest()
        with wave.open(io.BytesIO(cue_bytes), "rb") as recording:
            properties = (recording.getframerate(), recording.getnchannels(), recording.getsampwidth(), recording.getcomptype())
            if properties != (SAMPLE_RATE, 1, 2, "NONE"):
                raise CueError(f"{path}: cue WAV must be 16 kHz mono PCM16")
            if recording.getnframes() != MARKER_SAMPLES + GUARD_SAMPLES + count + TAIL_SAMPLES:
                raise CueError(f"{path}: cue WAV duration differs from descriptor")
            initial = recording.readframes(MARKER_SAMPLES)
            if initial != little_endian_bytes(marker_pcm()):
                raise CueError(f"{path}: cue WAV does not begin with the expected marker")
    except (OSError, wave.Error, EOFError) as exc:
        raise CueError(f"{path}: cannot read cue WAV: {exc}") from exc
    if actual_hash != descriptor.get("cue_sha256"):
        raise CueError(f"{path}: cue WAV SHA-256 does not match descriptor")
    if descriptor.get("analysis_start_offset_samples") != MARKER_SAMPLES + GUARD_SAMPLES + TRIM_SAMPLES or descriptor.get("analysis_end_offset_samples") != MARKER_SAMPLES + GUARD_SAMPLES + count - TRIM_SAMPLES:
        raise CueError(f"{path}: analysis offsets are inconsistent")
    return descriptor


def archive_pcm(path: Path) -> tuple[str, list[tuple[str, Any]], list[int]]:
    """Read a continuous archive. Early segment rotation means a known gap."""
    try:
        archive = zipfile.ZipFile(path)
    except (OSError, zipfile.BadZipFile) as exc:
        raise CueError(f"{path}: cannot open ZIP: {exc}") from exc
    with archive:
        def bounded_read(entry: zipfile.ZipInfo, maximum: int) -> bytes:
            with archive.open(entry) as source:
                contents = source.read(maximum + 1)
                if len(contents) > maximum or source.read(1):
                    raise CueError(f"{path}: ZIP entry {entry.filename} exceeds {maximum} bytes")
            return contents

        names = archive.namelist()
        if len(names) != len(set(names)):
            raise CueError(f"{path}: duplicate ZIP entries")
        entries = {entry.filename: entry for entry in archive.infolist()}
        session_entry = entries.get("session.json")
        if session_entry is None or session_entry.file_size > 65_536:
            raise CueError(f"{path}: missing or oversized session.json")
        try:
            session = json.loads(bounded_read(session_entry, 65_536).decode("utf-8"))
            session_id = str(uuid.UUID(session["id"]))
        except (KeyError, TypeError, ValueError, UnicodeError, json.JSONDecodeError,
                OSError, zipfile.BadZipFile, RuntimeError) as exc:
            raise CueError(f"{path}: invalid session.json.id: {exc}") from exc
        wav_names = sorted(name for name in names if WAV_NAME.fullmatch(name))
        if any(name.startswith("audio-") and not WAV_NAME.fullmatch(name) for name in names):
            raise CueError(f"{path}: unexpected audio-* ZIP entry")
        if not wav_names:
            raise CueError(f"{path}: no subtitle audio WAV")
        if len(wav_names) > MAX_SEGMENTS or sum(entries[name].file_size for name in wav_names) > MAX_SEGMENTS * MAX_ZIP_WAV_BYTES:
            raise CueError(f"{path}: pilot ZIP exceeds 5-minute WAV/segment safety limit")
        expected = [f"audio-{index:04d}.wav" for index in range(len(wav_names))]
        if wav_names != expected:
            raise CueError(f"{path}: WAV segments must be consecutive from audio-0000.wav")
        try:
            import numpy as np
        except ImportError as exc:
            raise CueError("locator needs NumPy: run python -m pip install numpy") from exc
        pieces = []
        offsets = [0]
        for index, name in enumerate(wav_names):
            entry = entries[name]
            if entry.file_size > MAX_ZIP_WAV_BYTES:
                raise CueError(f"{path}: {name} exceeds 60-second PCM limit")
            try:
                with wave.open(io.BytesIO(bounded_read(entry, MAX_ZIP_WAV_BYTES)), "rb") as recording:
                    properties = (recording.getframerate(), recording.getnchannels(), recording.getsampwidth(), recording.getcomptype())
                    if properties != (SAMPLE_RATE, 1, 2, "NONE"):
                        raise CueError(f"{path}: {name} must be 16 kHz mono PCM16")
                    count = recording.getnframes()
                    raw = recording.readframes(count)
            except (OSError, zipfile.BadZipFile, RuntimeError, wave.Error, EOFError) as exc:
                raise CueError(f"{path}: cannot read {name}: {exc}") from exc
            if len(raw) != count * 2 or count > NORMAL_SEGMENT_SAMPLES:
                raise CueError(f"{path}: invalid length for {name}")
            if index < len(wav_names) - 1 and count != NORMAL_SEGMENT_SAMPLES:
                raise CueError(f"{path}: {name} rotated before 60 seconds; possible audio gap")
            if offsets[-1] + count > MAX_TOTAL_SAMPLES:
                raise CueError(f"{path}: pilot recording exceeds 5-minute safety limit")
            pieces.append(np.frombuffer(raw, dtype="<i2").copy())
            offsets.append(offsets[-1] + count)
        return session_id, list(zip(wav_names, pieces)), offsets


def find_markers(samples: Any, expected_count: int) -> list[dict[str, Any]]:
    """FFT matched-filter candidate search; a count mismatch is an error."""
    import numpy as np

    template = np.asarray(marker_pcm(), dtype=np.float64)[::2] / 32768.0
    recording = samples[::2].astype(np.float64) / 32768.0
    if len(recording) < len(template):
        raise CueError("recording is shorter than one marker")
    fft_size = 1 << (len(recording) + len(template) - 2).bit_length()
    correlation = np.fft.irfft(
        np.fft.rfft(recording, fft_size) * np.conj(np.fft.rfft(template, fft_size)), fft_size
    )[: len(recording) - len(template) + 1]
    square_sum = np.r_[0.0, np.cumsum(recording * recording)]
    local_energy = square_sum[len(template):] - square_sum[:-len(template)]
    denominator = np.sqrt(np.maximum(local_energy, 1e-12) * np.dot(template, template))
    scores = np.abs(correlation) / denominator
    candidates = np.flatnonzero(scores >= MIN_CORRELATION)
    accepted: list[tuple[int, float]] = []
    # The high threshold prefilter is sparse outside the deliberately played chirps.
    for candidate in candidates[np.argsort(scores[candidates])[::-1]]:
        start = int(candidate) * 2
        if all(abs(start - earlier) >= MIN_MARKER_SEPARATION_SAMPLES for earlier, _ in accepted):
            accepted.append((start, float(scores[candidate])))
            if len(accepted) > expected_count:
                break
    accepted.sort()
    if len(accepted) != expected_count:
        raise CueError(
            f"found {len(accepted)} acoustic markers, expected {expected_count}; "
            "inspect the WAV and replay the entire round if any marker is missing, extra or ambiguous"
        )
    return [{"onset_sample_in_continuous_audio": start, "correlation": round(score, 4)} for start, score in accepted]


def window_for(onset: int, descriptor: dict[str, Any], pieces: list[tuple[str, Any]], offsets: list[int]) -> dict[str, int | str]:
    start = onset + descriptor["analysis_start_offset_samples"]
    end = onset + descriptor["analysis_end_offset_samples"]
    if end > offsets[-1]:
        raise CueError("analysis window extends beyond recorded audio")
    start_segment = bisect.bisect_right(offsets, start) - 1
    end_segment = bisect.bisect_right(offsets, end - 1) - 1
    if start_segment != end_segment:
        raise CueError("a speech analysis window crosses a 60-second WAV boundary; replay the round")
    return {
        "wav": pieces[start_segment][0],
        "start_sample": start - offsets[start_segment],
        "end_sample": end - offsets[start_segment],
    }


def require_string(value: Any, where: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise CueError(f"{where}: expected non-empty string")
    return value


def locate(plan_path: Path, output_path: Path, report_path: Path) -> None:
    if output_path.resolve() == report_path.resolve():
        raise CueError("candidate output and marker report must use different paths")
    try:
        plan = json.loads(plan_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise CueError(f"cannot read round plan: {exc}") from exc
    if not isinstance(plan, dict) or plan.get("schema_version") != 1 or plan.get("pilot_type") != "single_movable_source":
        raise CueError("round plan must use schema_version=1, pilot_type=single_movable_source")
    geometry_id = require_string(plan.get("geometry_id"), "geometry_id")
    rounds = plan.get("rounds")
    if not isinstance(rounds, list) or not rounds:
        raise CueError("rounds must be a non-empty list")
    material_ids: set[str] = set()
    source_hashes: set[str] = set()
    round_ids: set[str] = set()
    archive_paths: set[Path] = set()
    archive_session_ids: set[str] = set()
    candidate_rounds = []
    marker_reports = []
    for round_index, raw_round in enumerate(rounds):
        where = f"rounds[{round_index}]"
        if not isinstance(raw_round, dict):
            raise CueError(f"{where}: expected object")
        round_id = require_string(raw_round.get("round_id"), f"{where}.round_id")
        if round_id in round_ids:
            raise CueError(f"{where}: duplicate round_id")
        round_ids.add(round_id)
        sequence = raw_round.get("sequence")
        if sequence not in ("ABBA", "BAAB"):
            raise CueError(f"{where}.sequence: expected ABBA or BAAB")
        order = raw_round.get("playback_order", ["front", "side"])
        if order not in (["front", "side"], ["side", "front"]):
            raise CueError(f"{where}.playback_order: expected front/side or side/front")
        raw_pairs = raw_round.get("pairs")
        if not isinstance(raw_pairs, list) or len(raw_pairs) != 2:
            raise CueError(f"{where}.pairs: expected two cue descriptor paths")
        descriptors = []
        for pair in raw_pairs:
            pair_name = require_string(pair, f"{where}.pairs")
            descriptor = read_descriptor((plan_path.parent / pair_name).resolve())
            if descriptor["material_id"] in material_ids:
                raise CueError(f"{where}: each pair needs a unique material_id")
            if descriptor["source_sha256"] in source_hashes:
                raise CueError(f"{where}: two pairs reuse the same speech WAV; use different material")
            material_ids.add(descriptor["material_id"])
            source_hashes.add(descriptor["source_sha256"])
            descriptors.append(descriptor)
        export_name = require_string(raw_round.get("export_zip"), f"{where}.export_zip")
        export_path = (plan_path.parent / export_name).resolve()
        if export_path in archive_paths:
            raise CueError(f"{where}: each round must use a different export ZIP")
        archive_paths.add(export_path)
        session_id, pieces, offsets = archive_pcm(export_path)
        if session_id in archive_session_ids:
            raise CueError(f"{where}: ZIPs repeat the same session.json.id")
        archive_session_ids.add(session_id)
        import numpy as np

        markers = find_markers(np.concatenate([part for _, part in pieces]), 8)
        for play_index in range(7):
            descriptor = descriptors[play_index // 4]
            cue_length = MARKER_SAMPLES + GUARD_SAMPLES + descriptor["source_samples"] + TAIL_SAMPLES
            first = markers[play_index]["onset_sample_in_continuous_audio"]
            second = markers[play_index + 1]["onset_sample_in_continuous_audio"]
            if second < first + cue_length - SAMPLE_RATE // 10:
                raise CueError(
                    f"{round_id}: markers {play_index + 1} and {play_index + 2} are too close "
                    "for the declared cue; inspect playback order"
                )
        blocks = []
        round_marker_reports = []
        for block_index in range(4):
            descriptor = descriptors[block_index // 2]
            windows = {}
            for play_index, position in enumerate(order):
                marker = markers[block_index * 2 + play_index]
                windows[position] = window_for(marker["onset_sample_in_continuous_audio"], descriptor, pieces, offsets)
                round_marker_reports.append({
                    "block_number": block_index + 1,
                    "planned_direction": LETTERS[sequence[block_index]],
                    "planned_position": position,
                    **marker,
                    "candidate_window": windows[position],
                })
            blocks.append({
                "direction": LETTERS[sequence[block_index]],
                "material_id": descriptor["material_id"],
                "geometry_id": geometry_id,
                "playback_order": list(order),
                "windows": windows,
                "valid": False,
                "invalid_reason": "pending manual marker, position, direction, packet and gap review",
            })
        export_relative = os.path.relpath(export_path, output_path.parent.resolve())
        candidate_rounds.append({
            "round_id": round_id, "export_zip": export_relative,
            "archive_session_id": session_id,
            "sequence": sequence, "blocks": blocks,
        })
        marker_reports.append({
            "round_id": round_id, "archive_session_id": session_id,
            "markers": round_marker_reports,
            "note": "Marker positions and windows are candidates; planned conditions are not device observations.",
        })
    candidate = {"schema_version": 1, "pilot_type": "single_movable_source", "rounds": candidate_rounds}
    report = {
        "schema_version": 1,
        "locator": "pickup-cue.py chirp_v1",
        "minimum_correlation": MIN_CORRELATION,
        "rounds": marker_reports,
        "required_review": [
            "Listen to each marker and check all eight assigned speech windows.",
            "Confirm one phone played each cue exactly once at the declared front or side position with fixed volume.",
            "Confirm App diagnostics show the requested direction was submitted and type 4 packets continued without detected gaps.",
            "Only after those checks, change each valid field to true and remove its invalid_reason.",
        ],
    }
    if output_path.exists() or report_path.exists():
        raise CueError("output or report already exists; preserve prior candidates and choose new paths")
    output_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(candidate, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def example_plan() -> dict[str, Any]:
    return {
        "schema_version": 1,
        "pilot_type": "single_movable_source",
        "geometry_id": "front-0deg-side-90deg-fixed-distance",
        "rounds": [{
            "round_id": "round-01",
            "sequence": "ABBA",
            "export_zip": "round-01.zip",
            "pairs": ["pair-01.cue.json", "pair-02.cue.json"],
            "playback_order": ["front", "side"],
        }],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--example-round-plan", action="store_true", help="print a one-round plan example")
    subcommands = parser.add_subparsers(dest="command")
    make_parser = subcommands.add_parser("make", help="generate one marked mono phone-playback cue")
    make_parser.add_argument("--source", required=True, type=Path, help="16 kHz mono PCM16 speech WAV")
    make_parser.add_argument("--material-id", required=True, help="unique ID for one fixed A/B pair")
    make_parser.add_argument("--out-dir", required=True, type=Path)
    locate_parser = subcommands.add_parser("locate", help="propose eight windows per exported round")
    locate_parser.add_argument("plan", type=Path, help="round plan JSON")
    locate_parser.add_argument("--output", required=True, type=Path, help="pilot manifest candidate JSON")
    locate_parser.add_argument("--report", type=Path, help="separate marker scores and review report")
    arguments = parser.parse_args()
    try:
        if arguments.example_round_plan:
            print(json.dumps(example_plan(), ensure_ascii=False, indent=2))
        elif arguments.command == "make":
            cue, descriptor = make(arguments.source, arguments.material_id, arguments.out_dir)
            print(f"cue={cue}\ndescriptor={descriptor}\nPlay this mono WAV once for each planned front/side measurement.")
        elif arguments.command == "locate":
            report = arguments.report or arguments.output.with_name(arguments.output.stem + ".locate-report.json")
            locate(arguments.plan, arguments.output, report)
            print(f"candidate={arguments.output}\nreport={report}\nAll blocks remain invalid until manual review.")
        else:
            parser.error("choose make or locate, or --example-round-plan")
    except CueError as exc:
        print(f"pickup-cue: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
