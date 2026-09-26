#!/usr/bin/env python3
"""Analyze preselected windows from a Turbo-IO subtitle audio export.

Usage: python scripts/analyze-pickup-direction.py manifest.json --output result.json
       python scripts/analyze-pickup-direction.py export.zip manifest.json

The first form reads each round's export_zip relative to the manifest directory.
The second form is a single-ZIP fallback for preanalysis of older manifests.

The manifest schema and an example are printed by --example-manifest. All windows
are specified in sample indices. This tool never searches for convenient windows,
separates the two sources in a mixed recording, or confirms a device effect.
"""

from __future__ import annotations

import argparse
import array
import io
import json
import math
import re
import statistics
import sys
import unicodedata
import uuid
import wave
import zipfile
from collections import Counter
from contextlib import ExitStack
from pathlib import Path
from typing import Any


SAMPLE_RATE = 16_000
# The App's subtitle archive accepts each WAV only up to this byte count.
MAX_WAV_BYTES = 9_600_044
MAX_TEXT_UNITS = 2000
WAV_NAME = re.compile(r"audio-[0-9]{4}\.wav\Z")
KINDS = ("target", "interferer", "mixed")
LETTERS = {"A": "around", "B": "ahead"}


class AnalysisError(ValueError):
    """Invalid experiment input. The message identifies the affected item."""


def require_object(value: Any, where: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise AnalysisError(f"{where}: expected an object")
    return value


def require_nonempty_string(value: Any, where: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise AnalysisError(f"{where}: expected a non-empty string")
    return value


def require_text(value: Any, where: str) -> str:
    if not isinstance(value, str):
        raise AnalysisError(f"{where}: expected a string")
    return value


def normalize_units(text: str, metric: str) -> list[str]:
    normalized = unicodedata.normalize("NFKC", text)
    if metric == "cer":
        return [
            char for char in normalized
            if not char.isspace() and not unicodedata.category(char).startswith("P")
        ]
    words = []
    for char in normalized.casefold():
        if char.isspace() or unicodedata.category(char).startswith("P"):
            words.append(" ")
        else:
            words.append(char)
    return "".join(words).split()


def edit_counts(reference: list[str], recognized: list[str]) -> dict[str, int]:
    """Levenshtein edits with stable diagonal/deletion/insertion tie breaking."""
    rows = len(reference) + 1
    columns = len(recognized) + 1
    # Distance cannot exceed 2000 after input validation; uint16 rows keep the
    # backtracking matrix bounded even at the allowed text length.
    distances = [array.array("H", [0]) * columns for _ in range(rows)]
    for i in range(rows):
        distances[i][0] = i
    for j in range(columns):
        distances[0][j] = j
    for i in range(1, rows):
        for j in range(1, columns):
            distances[i][j] = min(
                distances[i - 1][j - 1] + (reference[i - 1] != recognized[j - 1]),
                distances[i - 1][j] + 1,
                distances[i][j - 1] + 1,
            )
    i, j = len(reference), len(recognized)
    substitutions = deletions = insertions = 0
    while i or j:
        if i and j and reference[i - 1] == recognized[j - 1] and distances[i][j] == distances[i - 1][j - 1]:
            i -= 1
            j -= 1
        elif i and j and distances[i][j] == distances[i - 1][j - 1] + 1:
            substitutions += 1
            i -= 1
            j -= 1
        elif i and distances[i][j] == distances[i - 1][j] + 1:
            deletions += 1
            i -= 1
        else:
            insertions += 1
            j -= 1
    return {
        "substitutions": substitutions,
        "deletions": deletions,
        "insertions": insertions,
        "edits": substitutions + deletions + insertions,
        "reference_units": len(reference),
    }


class WAVArchive:
    def __init__(self, archive_path: Path):
        try:
            self.archive = zipfile.ZipFile(archive_path)
        except (OSError, zipfile.BadZipFile) as exc:
            raise AnalysisError(f"ZIP: cannot open archive: {exc}") from exc
        names = self.archive.namelist()
        if len(names) != len(set(names)):
            self.archive.close()
            raise AnalysisError("ZIP: duplicate entry names are ambiguous")
        self.entries = {entry.filename: entry for entry in self.archive.infolist()}
        try:
            session_entry = self.entries.get("session.json")
            if session_entry is None or session_entry.is_dir() or session_entry.file_size > 65_536:
                raise AnalysisError("ZIP: missing or oversized session.json")
            session = json.loads(self.archive.read("session.json").decode("utf-8"))
            session = require_object(session, "ZIP session.json")
            self.session_id = str(uuid.UUID(require_nonempty_string(session.get("id"), "ZIP session.json.id")))
        except (OSError, zipfile.BadZipFile, RuntimeError, UnicodeError, json.JSONDecodeError, ValueError) as exc:
            self.archive.close()
            if isinstance(exc, AnalysisError):
                raise
            raise AnalysisError(f"ZIP: invalid session.json: {exc}") from exc
        self.cache: dict[str, array.array[int]] = {}

    def __enter__(self) -> WAVArchive:
        return self

    def __exit__(self, *_: Any) -> None:
        self.archive.close()

    def samples(self, name: str) -> array.array[int]:
        if not WAV_NAME.fullmatch(name):
            raise AnalysisError(f"WAV {name!r}: expected a flat audio-0000.wav entry")
        if name in self.cache:
            return self.cache[name]
        entry = self.entries.get(name)
        if entry is None or entry.is_dir():
            raise AnalysisError(f"WAV {name!r}: missing from ZIP")
        if entry.file_size > MAX_WAV_BYTES:
            raise AnalysisError(f"WAV {name!r}: exceeds {MAX_WAV_BYTES} byte analysis limit")
        try:
            contents = self.archive.read(name)
            with wave.open(io.BytesIO(contents), "rb") as wav:
                properties = (wav.getframerate(), wav.getnchannels(), wav.getsampwidth(), wav.getcomptype())
                if properties != (SAMPLE_RATE, 1, 2, "NONE"):
                    raise AnalysisError(
                        f"WAV {name!r}: expected 16000 Hz, mono, PCM16; got "
                        f"{properties[0]} Hz, {properties[1]} channel(s), "
                        f"{properties[2] * 8}-bit, compression={properties[3]}"
                    )
                count = wav.getnframes()
                raw = wav.readframes(count)
            if len(raw) != count * 2:
                raise AnalysisError(f"WAV {name!r}: truncated PCM data")
        except (OSError, zipfile.BadZipFile, RuntimeError, wave.Error, EOFError) as exc:
            raise AnalysisError(f"WAV {name!r}: cannot decode: {exc}") from exc
        pcm = array.array("h")
        pcm.frombytes(raw)
        if sys.byteorder != "little":
            pcm.byteswap()
        self.cache[name] = pcm
        return pcm


def read_window(archive: WAVArchive, raw: Any, where: str, *, acoustic: bool) -> tuple[dict[str, Any], float | None]:
    window = require_object(raw, where)
    name = require_nonempty_string(window.get("wav"), f"{where}.wav")
    start = window.get("start_sample")
    end = window.get("end_sample")
    if type(start) is not int or type(end) is not int or start < 0 or end <= start:
        raise AnalysisError(f"{where}: require integer 0 <= start_sample < end_sample")
    samples = archive.samples(name)
    if end > len(samples):
        raise AnalysisError(f"{where}: end_sample {end} exceeds WAV length {len(samples)}")
    # Mixed playback is validated as a WAV interval but never measured or separated.
    rms = None
    if acoustic:
        # The predeclared interval is used exactly, including any low-level samples.
        rms = math.sqrt(sum(sample * sample for sample in memoryview(samples)[start:end]) / (end - start))
        if rms == 0:
            raise AnalysisError(f"{where}: all-zero window cannot provide a non-silent dBFS value")
    elif not any(memoryview(samples)[start:end]):
        raise AnalysisError(f"{where}: all-zero mixed window is not a valid playback interval")
    return {"wav": name, "start_sample": start, "end_sample": end, "sample_count": end - start}, rms


def dbfs(rms: float) -> float:
    return 20 * math.log10(rms / 32768)


def validate_nonoverlap(windows: dict[str, dict[str, Any]], where: str) -> None:
    for i, first_name in enumerate(KINDS):
        first = windows[first_name]
        for second_name in KINDS[i + 1:]:
            second = windows[second_name]
            if first["wav"] == second["wav"] and max(first["start_sample"], second["start_sample"]) < min(first["end_sample"], second["end_sample"]):
                raise AnalysisError(f"{where}: {first_name} and {second_name} windows overlap")


def window_position(window: dict[str, Any]) -> tuple[int, int]:
    return int(window["wav"][6:10]), window["start_sample"]


def analyze(archive_path: Path | None, manifest: dict[str, Any], *, manifest_dir: Path | None = None) -> dict[str, Any]:
    manifest = require_object(manifest, "manifest")
    if type(manifest.get("schema_version")) is not int or manifest["schema_version"] != 1:
        raise AnalysisError("manifest.schema_version: expected 1")
    metric = manifest.get("text_metric")
    if metric not in ("cer", "wer"):
        raise AnalysisError("manifest.text_metric: expected 'cer' (Chinese) or 'wer' (English)")
    rounds = manifest.get("rounds")
    if not isinstance(rounds, list) or not rounds:
        raise AnalysisError("manifest.rounds: expected a non-empty list")
    identifiers: set[str] = set()
    output_rounds: list[dict[str, Any]] = []
    output_blocks: list[dict[str, Any]] = []
    output_pairs: list[dict[str, Any]] = []
    round_counts = {"ABBA": 0, "BAAB": 0}
    geometry_ids: set[str] = set()
    claimed_windows: dict[tuple[str, str], list[tuple[int, int, str]]] = {}
    paired_material_ids: set[str] = set()
    round_archive_keys: dict[str, str] = {}
    round_session_ids: dict[str, str] = {}
    archives: dict[str, WAVArchive] = {}
    with ExitStack() as stack:
        for round_index, raw_round in enumerate(rounds):
            where = f"rounds[{round_index}]"
            item = require_object(raw_round, where)
            round_id = require_nonempty_string(item.get("round_id"), f"{where}.round_id")
            if round_id in identifiers:
                raise AnalysisError(f"{where}.round_id: duplicate {round_id!r}")
            identifiers.add(round_id)
            export_name = item.get("export_zip")
            if export_name is None:
                if archive_path is None:
                    raise AnalysisError(f"{where}.export_zip: required when no fallback ZIP is passed")
                export_path = archive_path
                export_label = archive_path.name
            else:
                export_label = require_nonempty_string(export_name, f"{where}.export_zip")
                export_path = Path(export_label)
                if not export_path.is_absolute():
                    export_path = (manifest_dir or Path.cwd()) / export_path
            archive_key = str(export_path.resolve())
            archive = archives.get(archive_key)
            if archive is None:
                archive = stack.enter_context(WAVArchive(Path(archive_key)))
                archives[archive_key] = archive
            declared_session_id = item.get("archive_session_id")
            if declared_session_id is not None:
                declared_session_id = require_nonempty_string(declared_session_id, f"{where}.archive_session_id")
                try:
                    declared_session_id = str(uuid.UUID(declared_session_id))
                except ValueError as exc:
                    raise AnalysisError(f"{where}.archive_session_id: expected UUID") from exc
                if declared_session_id != archive.session_id:
                    raise AnalysisError(f"{where}.archive_session_id: does not match ZIP session.json.id")
            round_archive_keys[round_id] = archive_key
            round_session_ids[round_id] = archive.session_id
            sequence = item.get("sequence")
            if sequence not in round_counts:
                raise AnalysisError(f"{where}.sequence: expected ABBA or BAAB")
            round_counts[sequence] += 1
            blocks = item.get("blocks")
            if not isinstance(blocks, list) or len(blocks) != 4:
                raise AnalysisError(f"{where}.blocks: expected exactly four ordered blocks")
            computed_blocks: list[dict[str, Any]] = []
            for block_index, raw_block in enumerate(blocks):
                block_where = f"{where}.blocks[{block_index}]"
                block = require_object(raw_block, block_where)
                direction = block.get("direction")
                expected = LETTERS[sequence[block_index]]
                if direction != expected:
                    raise AnalysisError(f"{block_where}.direction: expected {expected!r} for {sequence}")
                material_id = require_nonempty_string(block.get("material_id"), f"{block_where}.material_id")
                geometry_id = require_nonempty_string(block.get("geometry_id"), f"{block_where}.geometry_id")
                geometry_ids.add(geometry_id)
                valid = block.get("valid", True)
                if type(valid) is not bool:
                    raise AnalysisError(f"{block_where}.valid: expected boolean")
                result: dict[str, Any] = {
                    "round_id": round_id,
                    "export_zip": export_label,
                    "block_number": block_index + 1,
                    "direction": direction,
                    "material_id": material_id,
                    "geometry_id": geometry_id,
                    "valid": valid,
                }
                if not valid:
                    result["invalid_reason"] = require_nonempty_string(block.get("invalid_reason"), f"{block_where}.invalid_reason")
                else:
                    all_windows = require_object(block.get("windows"), f"{block_where}.windows")
                    windows: dict[str, dict[str, Any]] = {}
                    levels: dict[str, float | None] = {}
                    for kind in KINDS:
                        windows[kind], levels[kind] = read_window(archive, all_windows.get(kind), f"{block_where}.windows.{kind}", acoustic=kind != "mixed")
                    validate_nonoverlap(windows, block_where)
                    if not (window_position(windows["target"]) < window_position(windows["interferer"]) < window_position(windows["mixed"])):
                        raise AnalysisError(f"{block_where}: windows must be in target, interferer, mixed playback order")
                    for kind in KINDS:
                        window = windows[kind]
                        claimed_windows.setdefault((archive_key, window["wav"]), []).append((window["start_sample"], window["end_sample"], f"{block_where}.{kind}"))
                    if windows["target"]["sample_count"] != windows["interferer"]["sample_count"]:
                        raise AnalysisError(f"{block_where}: target and interferer windows must have equal sample counts")
                    reference = require_text(block.get("reference"), f"{block_where}.reference")
                    recognized = require_text(block.get("recognized"), f"{block_where}.recognized")
                    reference_units = normalize_units(reference, metric)
                    if not reference_units:
                        raise AnalysisError(f"{block_where}.reference: empty after text normalization")
                    recognized_units = normalize_units(recognized, metric)
                    if len(reference_units) > MAX_TEXT_UNITS or len(recognized_units) > MAX_TEXT_UNITS:
                        raise AnalysisError(f"{block_where}: normalized reference and recognized text must each have at most {MAX_TEXT_UNITS} units")
                    counts = edit_counts(reference_units, recognized_units)
                    assert levels["target"] is not None and levels["interferer"] is not None
                    target_dbfs = dbfs(levels["target"])
                    interferer_dbfs = dbfs(levels["interferer"])
                    result.update({
                        "windows": windows,
                        "target_rms_pcm": levels["target"],
                        "interferer_rms_pcm": levels["interferer"],
                        "target_dbfs": target_dbfs,
                        "interferer_dbfs": interferer_dbfs,
                        "r_db": target_dbfs - interferer_dbfs,
                        "text": {"metric": metric, "reference": reference, "recognized": recognized, **counts, "error_rate": counts["edits"] / counts["reference_units"]},
                    })
                computed_blocks.append(result)
                output_blocks.append(result)
            first_pair_index = len(output_pairs)
            for first_index in (0, 2):
                first = computed_blocks[first_index]
                second = computed_blocks[first_index + 1]
                pair_where = f"{where}.blocks[{first_index}:{first_index + 2}]"
                if first["material_id"] != second["material_id"]:
                    raise AnalysisError(f"{pair_where}: adjacent A/B blocks require the same material_id")
                if first["geometry_id"] != second["geometry_id"]:
                    raise AnalysisError(f"{pair_where}: adjacent A/B blocks require the same geometry_id")
                pair: dict[str, Any] = {
                    "round_id": round_id,
                    "block_numbers": [first_index + 1, first_index + 2],
                    "material_id": first["material_id"],
                    "geometry_id": first["geometry_id"],
                    "transition": f"{first['direction']}->{second['direction']}",
                    "valid": first["valid"] and second["valid"],
                }
                if pair["valid"]:
                    if first["material_id"] in paired_material_ids:
                        raise AnalysisError(f"{pair_where}: valid paired material_id {first['material_id']!r} is reused")
                    paired_material_ids.add(first["material_id"])
                    for kind in ("target", "interferer"):
                        if first["windows"][kind]["sample_count"] != second["windows"][kind]["sample_count"]:
                            raise AnalysisError(f"{pair_where}: paired {kind} windows must have equal sample counts")
                    # Equal reference units mean the two ASR measurements concern the
                    # same spoken target even if punctuation differs in the manifest.
                    raw_first = blocks[first_index]
                    raw_second = blocks[first_index + 1]
                    if normalize_units(raw_first["reference"], metric) != normalize_units(raw_second["reference"], metric):
                        raise AnalysisError(f"{pair_where}: paired reference texts must match")
                    ahead, around = (first, second) if first["direction"] == "ahead" else (second, first)
                    pair.update({
                        "delta_r_db": ahead["r_db"] - around["r_db"],
                        "delta_f_db": ahead["target_dbfs"] - around["target_dbfs"],
                        "delta_text_error_rate": around["text"]["error_rate"] - ahead["text"]["error_rate"],
                    })
                else:
                    pair["invalid_reason"] = "one or both adjacent blocks are invalid"
                output_pairs.append(pair)
            valid_count = sum(block["valid"] for block in computed_blocks)
            output_rounds.append({
                "round_id": round_id,
                "sequence": sequence,
                "export_zip": export_label,
                "archive_session_id": archive.session_id,
                "valid_blocks": valid_count,
                "complete_valid_round": valid_count == 4 and all(pair["valid"] for pair in output_pairs[first_pair_index:]),
            })

    if len(geometry_ids) != 1:
        raise AnalysisError("manifest: all blocks must use one geometry_id; analyze different source angles separately")
    for (archive_key, name), claims in claimed_windows.items():
        claims.sort()
        for previous, current in zip(claims, claims[1:]):
            if previous[1] > current[0]:
                raise AnalysisError(f"ZIP {Path(archive_key).name!r}, WAV {name!r}: {previous[2]} overlaps {current[2]} across blocks")

    valid_blocks = sum(block["valid"] for block in output_blocks)
    valid_pairs = [pair for pair in output_pairs if pair["valid"]]
    count_pairs = len(valid_pairs)
    valid_round_counts = {"ABBA": 0, "BAAB": 0}
    complete_rounds = [round_item for round_item in output_rounds if round_item["complete_valid_round"]]
    archive_uses = Counter(round_archive_keys[round_item["round_id"]] for round_item in complete_rounds)
    session_uses = Counter(round_session_ids[round_item["round_id"]] for round_item in complete_rounds)
    independent_valid_round_counts = {"ABBA": 0, "BAAB": 0}
    for round_item in output_rounds:
        if round_item["complete_valid_round"]:
            valid_round_counts[round_item["sequence"]] += 1
        key = round_archive_keys[round_item["round_id"]]
        session_id = round_session_ids[round_item["round_id"]]
        independent = round_item["complete_valid_round"] and archive_uses[key] == 1 and session_uses[session_id] == 1
        round_item["independent_session"] = independent
        if independent:
            independent_valid_round_counts[round_item["sequence"]] += 1
    full_design = all(independent_valid_round_counts[sequence] >= 3 for sequence in round_counts) and valid_blocks >= 24 and count_pairs >= 12
    median_delta_r = statistics.median(pair["delta_r_db"] for pair in valid_pairs) if valid_pairs else None
    median_delta_f = statistics.median(pair["delta_f_db"] for pair in valid_pairs) if valid_pairs else None
    median_delta_text = statistics.median(pair["delta_text_error_rate"] for pair in valid_pairs) if valid_pairs else None
    positive = sum(pair["delta_r_db"] > 0 for pair in valid_pairs)
    pooled: dict[str, dict[str, Any]] = {}
    for direction in ("around", "ahead"):
        relevant = []
        pair_ids = {(pair["round_id"], number) for pair in valid_pairs for number in pair["block_numbers"]}
        for block in output_blocks:
            if block["direction"] == direction and (block["round_id"], block["block_number"]) in pair_ids:
                relevant.append(block)
        edits = sum(block["text"]["edits"] for block in relevant)
        units = sum(block["text"]["reference_units"] for block in relevant)
        pooled[direction] = {"edits": edits, "reference_units": units, "error_rate": edits / units if units else None}
    text_improvement = (pooled["around"]["error_rate"] > pooled["ahead"]["error_rate"]) if count_pairs else None
    positive_rate = positive / count_pairs if count_pairs else None
    thresholds = {
        "median_delta_r_ge_3_db": {"observed": median_delta_r, "required": 3.0, "met": median_delta_r >= 3.0 if full_design else None},
        "positive_delta_r_ge_10_of_12": {"observed_count": positive, "pair_count": count_pairs, "required_fraction": 10 / 12, "met": positive >= 10 and positive_rate >= 10 / 12 if full_design else None},
        "median_delta_f_ge_minus_3_db": {"observed": median_delta_f, "required": -3.0, "met": median_delta_f >= -3.0 if full_design else None},
        "mixed_text_error_lower_ahead": {"observed_around": pooled["around"]["error_rate"], "observed_ahead": pooled["ahead"]["error_rate"], "met": text_improvement if full_design else None},
    }
    return {
        "schema_version": 1,
        "method": {
            "windows": "manifest sample intervals only; no amplitude-based trimming",
            "sample_format": "16000 Hz mono PCM16",
            "archive_session_id": "UUID from ZIP session.json; it is not the business-protocol SID",
            "target_and_interferer": "separately played windows; R is an acoustic proxy, not mixed-source SNR",
            "mixed": "text error only; no source separation or mixed-source level estimate",
            "mixed_transcript_attribution": "reference and recognized text are assigned to each block by the operator; this tool does not align ASR text to audio",
            "material_id": "operator-declared source identity; the analyzer cannot verify playback files or source positions",
            "text_normalization": "NFKC; CER removes whitespace/punctuation, WER casefolds and splits on whitespace/punctuation",
        },
        "rounds": output_rounds,
        "blocks": output_blocks,
        "pairs": output_pairs,
        "summary": {
            "round_counts": round_counts,
            "valid_round_counts": valid_round_counts,
            "independent_valid_round_counts": independent_valid_round_counts,
            "planned_blocks": len(output_blocks),
            "valid_blocks": valid_blocks,
            "valid_pairs": count_pairs,
            "full_design_evidence": full_design,
            "full_design_scope": "quantity and independence of valid rounds only; wire, audio continuity, and firmware behavior remain external checks",
            "evidence_level": "full_design_quantification" if full_design else "preanalysis_insufficient",
            "median_delta_r_db": median_delta_r,
            "positive_delta_r_pairs": positive,
            "positive_delta_r_fraction": positive_rate,
            "median_delta_f_db": median_delta_f,
            "median_delta_text_error_rate": median_delta_text,
            "pooled_mixed_text": {"metric": metric, **pooled},
            "quantitative_conditions": thresholds,
            "external_checks_required": [
                "Turbo-IO application-layer type 10 direction and current protocol SID, plus SDK send and asynchronous failure results",
                "uninterrupted type 4 audio and no gap in each valid block",
                "quiet target-only ASR quality and audible distortion",
                "repeatable A-to-B-to-A acoustic effect on the target glasses and firmware with stable geometry, source levels, and ASR settings",
            ],
            "optional_cross_checks": [
                "official Android app type 1/type 2/type 10 application-layer capture and current protocol SID",
            ],
            "device_effect_confirmed": None,
            "device_effect_note": "This analyzer cannot confirm that firmware applied the command or that directional pickup is effective.",
        },
    }


EXAMPLE = {
    "schema_version": 1,
    "text_metric": "cer",
    "rounds": [{
        "round_id": "round-01",
        "export_zip": "round-01.zip",
        "sequence": "ABBA",
        "blocks": [{
            "direction": direction,
            "material_id": "speech-pair-01" if index < 2 else "speech-pair-02",
            "geometry_id": "target-0deg-interferer-90deg",
            "windows": {
                "target": {"wav": "audio-0000.wav", "start_sample": index * 48000, "end_sample": index * 48000 + 16000},
                "interferer": {"wav": "audio-0000.wav", "start_sample": index * 48000 + 16000, "end_sample": index * 48000 + 32000},
                "mixed": {"wav": "audio-0000.wav", "start_sample": index * 48000 + 32000, "end_sample": index * 48000 + 48000},
            },
            "reference": "今天阳光很好",
            "recognized": "今天阳光很好",
        } for index, direction in enumerate(("around", "ahead", "ahead", "around"))],
    }],
}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("paths", nargs="*", type=Path, help="manifest.json, or legacy export.zip manifest.json")
    parser.add_argument("--output", type=Path, help="write JSON here; default stdout")
    parser.add_argument("--example-manifest", action="store_true", help="print a one-round example (preanalysis only)")
    args = parser.parse_args(argv)
    if args.example_manifest:
        print(json.dumps(EXAMPLE, ensure_ascii=False, indent=2))
        return 0
    if len(args.paths) == 1:
        export_zip = None
        manifest_path = args.paths[0]
    elif len(args.paths) == 2:
        export_zip, manifest_path = args.paths
    else:
        parser.error("provide manifest.json, or legacy export.zip manifest.json")
    try:
        with manifest_path.open("r", encoding="utf-8") as file:
            manifest = json.load(file)
        result = analyze(export_zip, manifest, manifest_dir=manifest_path.parent.resolve())
        encoded = json.dumps(result, ensure_ascii=False, indent=2, allow_nan=False) + "\n"
        if args.output is None:
            sys.stdout.write(encoded)
        else:
            args.output.write_text(encoded, encoding="utf-8")
    except (AnalysisError, OSError, UnicodeError, json.JSONDecodeError) as exc:
        parser.exit(2, f"analysis error: {exc}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
