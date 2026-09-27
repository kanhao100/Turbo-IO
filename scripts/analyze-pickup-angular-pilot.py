#!/usr/bin/env python3
"""Measure solo-source front/side angular response from subtitle export ZIPs.

This is a pilot for one movable playback phone, not a two-source interference
experiment. It never infers a firmware acknowledgement or mixed-speech benefit.

Usage:
    python scripts/analyze-pickup-angular-pilot.py manifest.json --output result.json
    python scripts/analyze-pickup-angular-pilot.py --example-manifest

Sample windows must be located in the exported WAV by their recorded acoustic
markers and then checked by the operator. The tool neither finds markers nor
chooses loud intervals automatically.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import statistics
import sys
import uuid
from collections import Counter
from contextlib import ExitStack
from pathlib import Path
from typing import Any


_FULL_ANALYZER = Path(__file__).with_name("analyze-pickup-direction.py")
_SPEC = importlib.util.spec_from_file_location("pickup_direction_zip_helpers", _FULL_ANALYZER)
if _SPEC is None or _SPEC.loader is None:
    raise RuntimeError(f"cannot load ZIP/WAV reader from {_FULL_ANALYZER}")
_HELPERS = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(_HELPERS)

AnalysisError = _HELPERS.AnalysisError
WAVArchive = _HELPERS.WAVArchive
require_object = _HELPERS.require_object
require_nonempty_string = _HELPERS.require_nonempty_string
read_window = _HELPERS.read_window
window_position = _HELPERS.window_position
dbfs = _HELPERS.dbfs

DIRECTIONS = {"A": "around", "B": "ahead"}
POSITIONS = {"front", "side"}


def _count_by_sequence(pairs: list[dict[str, Any]], rounds: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    sequence_by_round = {item["round_id"]: item["sequence"] for item in rounds}
    grouped = {"ABBA": [], "BAAB": []}
    for pair in pairs:
        grouped[sequence_by_round[pair["round_id"]]].append(pair["delta_r_db"])
    return {
        sequence: {
            "pairs": len(values),
            "positive_delta_r_pairs": sum(value > 0 for value in values),
            "median_delta_r_db": statistics.median(values) if values else None,
        }
        for sequence, values in grouped.items()
    }


def analyze(manifest: dict[str, Any], *, manifest_dir: Path | None = None) -> dict[str, Any]:
    manifest = require_object(manifest, "manifest")
    if type(manifest.get("schema_version")) is not int or manifest["schema_version"] != 1:
        raise AnalysisError("manifest.schema_version: expected 1")
    if manifest.get("pilot_type") != "single_movable_source":
        raise AnalysisError("manifest.pilot_type: expected 'single_movable_source'")
    raw_rounds = manifest.get("rounds")
    if not isinstance(raw_rounds, list) or not raw_rounds:
        raise AnalysisError("manifest.rounds: expected a non-empty list")

    rounds: list[dict[str, Any]] = []
    blocks: list[dict[str, Any]] = []
    pairs: list[dict[str, Any]] = []
    round_ids: set[str] = set()
    round_archive_keys: dict[str, str] = {}
    round_session_ids: dict[str, str] = {}
    geometry_ids: set[str] = set()
    claimed_windows: dict[tuple[str, str], list[tuple[int, int, str]]] = {}
    archives: dict[str, WAVArchive] = {}

    with ExitStack() as stack:
        for round_index, raw_round in enumerate(raw_rounds):
            where = f"rounds[{round_index}]"
            item = require_object(raw_round, where)
            round_id = require_nonempty_string(item.get("round_id"), f"{where}.round_id")
            if round_id in round_ids:
                raise AnalysisError(f"{where}.round_id: duplicate {round_id!r}")
            round_ids.add(round_id)
            export_label = require_nonempty_string(item.get("export_zip"), f"{where}.export_zip")
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
            if sequence not in ("ABBA", "BAAB"):
                raise AnalysisError(f"{where}.sequence: expected ABBA or BAAB")
            raw_blocks = item.get("blocks")
            if not isinstance(raw_blocks, list) or len(raw_blocks) != 4:
                raise AnalysisError(f"{where}.blocks: expected exactly four ordered blocks")
            computed_blocks: list[dict[str, Any]] = []
            for block_index, raw_block in enumerate(raw_blocks):
                block_where = f"{where}.blocks[{block_index}]"
                block = require_object(raw_block, block_where)
                direction = block.get("direction")
                expected = DIRECTIONS[sequence[block_index]]
                if direction != expected:
                    raise AnalysisError(f"{block_where}.direction: expected {expected!r} for {sequence}")
                material_id = require_nonempty_string(block.get("material_id"), f"{block_where}.material_id")
                geometry_id = require_nonempty_string(block.get("geometry_id"), f"{block_where}.geometry_id")
                geometry_ids.add(geometry_id)
                valid = block.get("valid")
                if type(valid) is not bool:
                    raise AnalysisError(f"{block_where}.valid: explicit boolean required after manual review")
                if valid and "invalid_reason" in block:
                    raise AnalysisError(f"{block_where}: valid=true conflicts with invalid_reason; remove the pending-review reason only after review")
                computed: dict[str, Any] = {
                    "round_id": round_id,
                    "export_zip": export_label,
                    "block_number": block_index + 1,
                    "direction": direction,
                    "material_id": material_id,
                    "geometry_id": geometry_id,
                    "valid": valid,
                }
                if not valid:
                    computed["invalid_reason"] = require_nonempty_string(block.get("invalid_reason"), f"{block_where}.invalid_reason")
                else:
                    playback_order = block.get("playback_order")
                    if (
                        not isinstance(playback_order, list)
                        or len(playback_order) != 2
                        or not all(isinstance(position, str) for position in playback_order)
                        or set(playback_order) != POSITIONS
                    ):
                        raise AnalysisError(f"{block_where}.playback_order: expected ['front','side'] or ['side','front']")
                    raw_windows = require_object(block.get("windows"), f"{block_where}.windows")
                    if set(raw_windows) != POSITIONS:
                        raise AnalysisError(f"{block_where}.windows: expected exactly front and side")
                    windows: dict[str, dict[str, Any]] = {}
                    levels: dict[str, float] = {}
                    for position in ("front", "side"):
                        window, rms = read_window(archive, raw_windows[position], f"{block_where}.windows.{position}", acoustic=True)
                        assert rms is not None
                        windows[position] = window
                        levels[position] = rms
                        claimed_windows.setdefault((archive_key, window["wav"]), []).append(
                            (window["start_sample"], window["end_sample"], f"{block_where}.{position}")
                        )
                    first, second = (windows[position] for position in playback_order)
                    if not window_position(first) < window_position(second):
                        raise AnalysisError(f"{block_where}: WAV windows contradict playback_order")
                    if windows["front"]["sample_count"] != windows["side"]["sample_count"]:
                        raise AnalysisError(f"{block_where}: front and side windows must have equal sample counts")
                    front_dbfs = dbfs(levels["front"])
                    side_dbfs = dbfs(levels["side"])
                    computed.update({
                        "playback_order": playback_order,
                        "windows": windows,
                        "front_rms_pcm": levels["front"],
                        "side_rms_pcm": levels["side"],
                        "front_dbfs": front_dbfs,
                        "side_dbfs": side_dbfs,
                        "r_db": front_dbfs - side_dbfs,
                    })
                computed_blocks.append(computed)
                blocks.append(computed)

            previous_valid: dict[str, Any] | None = None
            for current in computed_blocks:
                if not current["valid"]:
                    continue
                first = current["windows"][current["playback_order"][0]]
                if previous_valid is not None:
                    last = previous_valid["windows"][previous_valid["playback_order"][1]]
                    last_end = (int(last["wav"][6:10]), last["end_sample"])
                    if last_end > window_position(first):
                        raise AnalysisError(
                            f"{where}: block {current['block_number']} windows precede or overlap "
                            f"block {previous_valid['block_number']}; blocks must follow playback order"
                        )
                previous_valid = current

            first_pair_index = len(pairs)
            for first_index in (0, 2):
                first = computed_blocks[first_index]
                second = computed_blocks[first_index + 1]
                pair_where = f"{where}.blocks[{first_index}:{first_index + 2}]"
                if first["material_id"] != second["material_id"]:
                    raise AnalysisError(f"{pair_where}: paired blocks require the same material_id")
                if first["geometry_id"] != second["geometry_id"]:
                    raise AnalysisError(f"{pair_where}: paired blocks require the same geometry_id")
                pair: dict[str, Any] = {
                    "round_id": round_id,
                    "block_numbers": [first_index + 1, first_index + 2],
                    "material_id": first["material_id"],
                    "geometry_id": first["geometry_id"],
                    "transition": f"{first['direction']}->{second['direction']}",
                    "valid": first["valid"] and second["valid"],
                }
                if pair["valid"]:
                    for position in ("front", "side"):
                        if first["windows"][position]["sample_count"] != second["windows"][position]["sample_count"]:
                            raise AnalysisError(f"{pair_where}: paired {position} windows must have equal sample counts")
                    ahead, around = (first, second) if first["direction"] == "ahead" else (second, first)
                    pair.update({
                        "delta_r_db": ahead["r_db"] - around["r_db"],
                        "delta_f_db": ahead["front_dbfs"] - around["front_dbfs"],
                        "delta_side_db": ahead["side_dbfs"] - around["side_dbfs"],
                    })
                else:
                    pair["invalid_reason"] = "one or both adjacent blocks are invalid"
                pairs.append(pair)
            valid_count = sum(block["valid"] for block in computed_blocks)
            rounds.append({
                "round_id": round_id,
                "sequence": sequence,
                "export_zip": export_label,
                "archive_session_id": archive.session_id,
                "valid_blocks": valid_count,
                "complete_valid_round": valid_count == 4 and all(pair["valid"] for pair in pairs[first_pair_index:]),
            })

    if len(geometry_ids) != 1:
        raise AnalysisError("manifest: all blocks must use one geometry_id; analyze different positions separately")
    for (archive_key, name), claims in claimed_windows.items():
        claims.sort()
        for previous, current in zip(claims, claims[1:]):
            if previous[1] > current[0]:
                raise AnalysisError(f"ZIP {Path(archive_key).name!r}, WAV {name!r}: {previous[2]} overlaps {current[2]} across windows")

    complete_rounds = [item for item in rounds if item["complete_valid_round"]]
    archive_uses = Counter(round_archive_keys[item["round_id"]] for item in complete_rounds)
    session_uses = Counter(round_session_ids[item["round_id"]] for item in complete_rounds)
    independent_round_ids: set[str] = set()
    for item in rounds:
        independent = (
            item["complete_valid_round"]
            and archive_uses[round_archive_keys[item["round_id"]]] == 1
            and session_uses[round_session_ids[item["round_id"]]] == 1
        )
        item["independent_session"] = independent
        if independent:
            independent_round_ids.add(item["round_id"])
    for item in blocks:
        item["included_in_quantification"] = item["valid"] and item["round_id"] in independent_round_ids
    for item in pairs:
        item["included_in_quantification"] = item["valid"] and item["round_id"] in independent_round_ids

    quantified_pairs = [item for item in pairs if item["included_in_quantification"]]
    material_ids: set[str] = set()
    for pair in quantified_pairs:
        if pair["material_id"] in material_ids:
            raise AnalysisError(f"quantified pairs: material_id {pair['material_id']!r} is reused")
        material_ids.add(pair["material_id"])
    delta_r_values = [pair["delta_r_db"] for pair in quantified_pairs]
    delta_f_values = [pair["delta_f_db"] for pair in quantified_pairs]
    positive = sum(value > 0 for value in delta_r_values)
    independent_counts = {sequence: sum(item["independent_session"] and item["sequence"] == sequence for item in rounds) for sequence in ("ABBA", "BAAB")}
    positive_pair_rounds = sum(
        all(pair["delta_r_db"] > 0 for pair in quantified_pairs if pair["round_id"] == round_id)
        for round_id in independent_round_ids
    )
    return {
        "schema_version": 1,
        "pilot_type": "single_movable_source",
        "method": {
            "sample_format": "16000 Hz mono PCM16 from subtitle ZIP",
            "windows": "operator-verified sample intervals from acoustic markers; no amplitude-based trimming",
            "positions": "one playback phone is moved between front and side; sources are never simultaneous",
            "material_id": "operator-declared identical local playback file within each pair; this tool cannot verify the file or placement",
            "archive_session_id": "UUID in ZIP session.json; not the business-protocol SID",
            "r_db": "front solo-playback dBFS minus side solo-playback dBFS",
            "delta_r_db": "R_ahead minus R_around, paired by blocks 1-2 and 3-4",
            "delta_f_db": "front solo-playback dBFS in ahead minus around",
        },
        "rounds": rounds,
        "blocks": blocks,
        "pairs": pairs,
        "summary": {
            "evidence_level": "single_source_angular_response_pilot",
            "scope": "descriptive angular response of a solo movable source; no mixed-source SNR, interference suppression, or mixed-speech ASR claim",
            "round_counts": {sequence: sum(item["sequence"] == sequence for item in rounds) for sequence in ("ABBA", "BAAB")},
            "independent_valid_round_counts": independent_counts,
            "planned_blocks": len(blocks),
            "raw_valid_blocks": sum(item["valid"] for item in blocks),
            "raw_valid_pairs": sum(item["valid"] for item in pairs),
            "quantified_blocks": sum(item["included_in_quantification"] for item in blocks),
            "quantified_pairs": len(quantified_pairs),
            "quantification_scope": "complete valid rounds with unique ZIP paths and session IDs; failed or duplicate rounds remain visible but are excluded",
            "median_delta_r_db": statistics.median(delta_r_values) if delta_r_values else None,
            "median_delta_f_db": statistics.median(delta_f_values) if delta_f_values else None,
            "positive_delta_r_pairs": positive,
            "positive_delta_r_fraction": positive / len(delta_r_values) if delta_r_values else None,
            "replication": {
                "independent_rounds": len(independent_round_ids),
                "rounds_with_both_pairs_positive": positive_pair_rounds,
                "by_sequence": _count_by_sequence(quantified_pairs, rounds),
            },
            "device_effect_confirmed": None,
            "external_checks_required": [
                "confirm current business-protocol SID and type 10 direction submission; SDK send is not a firmware application ACK",
                "confirm type 4 audio continues without detected gaps in every measured block",
                "verify fixed phone volume, distance, height, facing, source file, glasses pose, and WAV marker alignment",
                "a separate simultaneous front-plus-side source experiment is needed to assess mixed-speech directionality",
            ],
        },
    }


EXAMPLE = {
    "schema_version": 1,
    "pilot_type": "single_movable_source",
    "rounds": [{
        "round_id": "round-01",
        "export_zip": "round-01.zip",
        "sequence": "ABBA",
        "blocks": [{
            "direction": direction,
            "material_id": f"phone-clip-pair-{index // 2 + 1:02d}",
            "geometry_id": "front-0deg-side-90deg-same-radius",
            "valid": False,
            "invalid_reason": "pending manual review of markers, geometry, and audio continuity",
            "playback_order": ["front", "side"],
            "windows": {
                "front": {"wav": "audio-0000.wav", "start_sample": index * 32_000, "end_sample": index * 32_000 + 16_000},
                "side": {"wav": "audio-0000.wav", "start_sample": index * 32_000 + 16_000, "end_sample": index * 32_000 + 32_000},
            },
        } for index, direction in enumerate(("around", "ahead", "ahead", "around"))],
    }],
}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", nargs="?", type=Path, help="JSON manifest with one export ZIP per round")
    parser.add_argument("--output", type=Path, help="write result JSON here (stdout by default)")
    parser.add_argument("--example-manifest", action="store_true", help="print a placeholder manifest and exit")
    args = parser.parse_args(argv)
    if args.example_manifest:
        print(json.dumps(EXAMPLE, ensure_ascii=False, indent=2))
        return 0
    if args.manifest is None:
        parser.error("manifest is required unless --example-manifest is used")
    try:
        manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
        result = analyze(manifest, manifest_dir=args.manifest.parent)
        output = json.dumps(result, ensure_ascii=False, indent=2, allow_nan=False) + "\n"
        if args.output:
            args.output.write_text(output, encoding="utf-8")
        else:
            print(output, end="")
    except (OSError, UnicodeError, json.JSONDecodeError, AnalysisError) as exc:
        print(f"analysis failed: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
