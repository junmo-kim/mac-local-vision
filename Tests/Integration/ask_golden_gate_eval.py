#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import platform
import subprocess
import sys
import tempfile
import time
from pathlib import Path

TIMEOUT_SECONDS = 120
ITERATIONS = 3
REQUIRED_SCHEMA_KEYS = {
    "summary",
    "scene_type",
    "qr_present",
    "dominant_color",
    "visible_item_count",
}
SCENE_TYPES = {"illustrated", "photograph", "other"}
DOMINANT_COLORS = {"blue", "green", "yellow", "red", "brown", "black", "white", "other"}
EXPECTED_VISIBLE_TEXT = "GOLDEN GATE EVAL"
EXPECTED_QR_PAYLOAD = "MACVIS-GOLDEN-GATE-2026"

SCHEMA = {
    "type": "object",
    "properties": {
        "summary": {"type": "string"},
        "scene_type": {"type": "string", "enum": sorted(SCENE_TYPES)},
        "qr_present": {"type": "boolean"},
        "dominant_color": {"type": "string", "enum": sorted(DOMINANT_COLORS)},
        "visible_item_count": {"type": "integer"},
    },
    "required": sorted(REQUIRED_SCHEMA_KEYS),
}

CASES = (
    (
        "free-text",
        "Describe the image briefly. Report visible text exactly and decode the exact QR payload if possible.",
        (),
    ),
    (
        "stream",
        "Summarize the scene briefly, report visible text exactly, and decode the exact QR payload if possible.",
        ("--stream",),
    ),
    (
        "schema",
        "Analyze the image. Use scene_type illustrated, photograph, or other; choose dominant_color from the allowed values; and estimate visible_item_count as an integer from 1 through 20.",
        ("--schema", "{schema_path}"),
    ),
)


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("binary", type=Path)
    parser.add_argument("--fixture", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--vision-tools-ab", action="store_true")
    return parser.parse_args()


def text(value):
    if value is None:
        return ""
    if isinstance(value, bytes):
        return value.decode("utf-8", errors="replace")
    return value


def invoke(command):
    started = time.monotonic_ns()
    try:
        completed = subprocess.run(
            command,
            capture_output=True,
            text=True,
            timeout=TIMEOUT_SECONDS,
            check=False,
        )
        return {
            "code": completed.returncode,
            "timed_out": False,
            "stdout": completed.stdout,
            "stderr": completed.stderr,
            "latency_ms": round((time.monotonic_ns() - started) / 1_000_000, 3),
        }
    except subprocess.TimeoutExpired as error:
        return {
            "code": None,
            "timed_out": True,
            "stdout": text(error.stdout),
            "stderr": text(error.stderr),
            "latency_ms": round((time.monotonic_ns() - started) / 1_000_000, 3),
        }


def parse_json(raw):
    try:
        return json.loads(raw), None
    except json.JSONDecodeError as error:
        return None, f"stdout_json: {error}"


def is_integer(value):
    return isinstance(value, int) and not isinstance(value, bool)


def validate(case_name, invocation):
    parsed, parse_failure = parse_json(invocation["stdout"])
    checks = {
        "exit_0": invocation["code"] == 0 and not invocation["timed_out"],
        "json_object": isinstance(parsed, dict),
    }
    failures = []
    if parse_failure:
        failures.append(parse_failure)

    answer = parsed.get("answer") if isinstance(parsed, dict) else None
    compute = parsed.get("compute") if isinstance(parsed, dict) else None
    checks["compute_on_device"] = compute == "on-device"

    if case_name in {"free-text", "stream"}:
        checks["answer_string"] = isinstance(answer, str)
        checks["answer_nonempty"] = isinstance(answer, str) and bool(answer.strip())
    else:
        checks.update({
            "answer_object": isinstance(answer, dict),
            "required_keys": isinstance(answer, dict) and REQUIRED_SCHEMA_KEYS <= set(answer),
            "summary_string": isinstance(answer, dict)
            and isinstance(answer.get("summary"), str)
            and bool(answer["summary"].strip()),
            "scene_type_enum": isinstance(answer, dict)
            and answer.get("scene_type") in SCENE_TYPES,
            "qr_present_boolean": isinstance(answer, dict)
            and isinstance(answer.get("qr_present"), bool),
            "dominant_color_enum": isinstance(answer, dict)
            and answer.get("dominant_color") in DOMINANT_COLORS,
            "visible_item_count_integer": isinstance(answer, dict)
            and is_integer(answer.get("visible_item_count")),
            "visible_item_count_range": isinstance(answer, dict)
            and is_integer(answer.get("visible_item_count"))
            and 1 <= answer["visible_item_count"] <= 20,
        })

    failures.extend(name for name, passed in checks.items() if not passed)
    sample = parsed if parsed is not None else {
        "stdout": invocation["stdout"][-4_096:],
        "stderr": invocation["stderr"][-4_096:],
    }
    searchable_answer = json.dumps(answer, ensure_ascii=False) if answer is not None else ""
    quality = {
        # Informational A/B metrics, deliberately not pass/fail gates: exact wording from a
        # generative answer is nondeterministic, while the structural contract above is stable.
        "visible_text_exact": EXPECTED_VISIBLE_TEXT.lower() in searchable_answer.lower(),
        "qr_payload_exact": EXPECTED_QR_PAYLOAD.lower() in searchable_answer.lower(),
    }
    return {
        "passed": not failures,
        "checks": checks,
        "failures": failures,
    }, quality, sample


def write_json_atomic(path, value):
    path = path.resolve()
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(value, handle, ensure_ascii=False, indent=2, sort_keys=True)
            handle.write("\n")
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def main():
    args = parse_args()
    binary = args.binary.resolve()
    fixture = args.fixture.resolve()
    output = args.output.resolve()

    doctor_invocation = invoke([str(binary), "doctor", "--format", "json"])
    doctor, doctor_error = parse_json(doctor_invocation["stdout"])
    doctor_available = (
        doctor_invocation["code"] == 0
        and not doctor_invocation["timed_out"]
        and isinstance(doctor, dict)
        and doctor.get("ask") == "available"
    )

    result = {
        "schema_version": 1,
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "binary": str(binary),
        "binary_version": "",
        "platform": platform.platform(),
        "timeout_seconds": TIMEOUT_SECONDS,
        "iterations_per_case": ITERATIONS,
        "vision_tools_ab": args.vision_tools_ab,
        "fixture": {
            "generator": "Tests/Integration/ask-golden-gate-fixture.swift",
            "sha256": hashlib.sha256(fixture.read_bytes()).hexdigest(),
            "width": 1_200,
            "height": 800,
            "features": ["text", "qr", "illustrated-general-scene"],
        },
        "doctor": {
            "latency_ms": doctor_invocation["latency_ms"],
            "exit": {
                "code": doctor_invocation["code"],
                "timed_out": doctor_invocation["timed_out"],
            },
            "ask": doctor.get("ask") if isinstance(doctor, dict) else None,
            "parse_error": doctor_error,
        },
        "calls": [],
    }

    version_invocation = invoke([str(binary), "--version"])
    if version_invocation["code"] == 0:
        result["binary_version"] = version_invocation["stdout"].strip()

    if not doctor_available:
        result["summary"] = {
            "passed": False,
            "reason": "doctor ask is not available",
            "total_calls": 0,
            "passed_calls": 0,
        }
        write_json_atomic(output, result)
        print(f"ask evaluation stopped: doctor ask is not available; result: {output}", file=sys.stderr)
        return 2

    modes = [("baseline", ())]
    if args.vision_tools_ab:
        help_invocation = invoke([str(binary), "ask", "--help"])
        if help_invocation["code"] != 0 or "--vision-tools" not in help_invocation["stdout"]:
            result["summary"] = {
                "passed": False,
                "reason": "--vision-tools-ab requested but the binary does not advertise --vision-tools",
                "total_calls": 0,
                "passed_calls": 0,
            }
            write_json_atomic(output, result)
            print(result["summary"]["reason"], file=sys.stderr)
            return 2
        modes.append(("vision-tools", ("--vision-tools",)))

    with tempfile.TemporaryDirectory(prefix="macvis-ask-eval-schema.") as temporary:
        schema_path = Path(temporary) / "scene-schema.json"
        schema_path.write_text(json.dumps(SCHEMA, sort_keys=True), encoding="utf-8")

        for mode_name, mode_flags in modes:
            for case_name, prompt, case_flags in CASES:
                resolved_case_flags = tuple(
                    str(schema_path) if value == "{schema_path}" else value
                    for value in case_flags
                )
                for iteration in range(1, ITERATIONS + 1):
                    command = [
                        str(binary),
                        "ask",
                        str(fixture),
                        "--prompt",
                        prompt,
                        *resolved_case_flags,
                        *mode_flags,
                        "--format",
                        "json",
                    ]
                    invocation = invoke(command)
                    contract, quality, sample = validate(case_name, invocation)
                    result["calls"].append({
                        "mode": mode_name,
                        "case": case_name,
                        "iteration": iteration,
                        "latency_ms": invocation["latency_ms"],
                        "exit": {
                            "code": invocation["code"],
                            "timed_out": invocation["timed_out"],
                        },
                        "contract": contract,
                        "quality": quality,
                        "sample": sample,
                        "stderr_sample": invocation["stderr"][-4_096:],
                    })
                    state = "PASS" if contract["passed"] else "FAIL"
                    print(
                        f"{state} {mode_name}/{case_name} #{iteration} "
                        f"exit={invocation['code']} latency_ms={invocation['latency_ms']}",
                        flush=True,
                    )

    passed_calls = sum(call["contract"]["passed"] for call in result["calls"])
    exit_codes = {}
    for call in result["calls"]:
        key = f"{call['mode']}/{call['case']}"
        exit_codes.setdefault(key, []).append(call["exit"]["code"])
    result["summary"] = {
        "passed": passed_calls == len(result["calls"]),
        "total_calls": len(result["calls"]),
        "passed_calls": passed_calls,
        "exit_codes_by_case": exit_codes,
        "quality_by_mode": {
            mode: {
                metric: {
                    "hits": sum(
                        call["quality"][metric]
                        for call in result["calls"]
                        if call["mode"] == mode
                    ),
                    "calls": sum(call["mode"] == mode for call in result["calls"]),
                }
                for metric in ("visible_text_exact", "qr_payload_exact")
            }
            for mode in sorted({call["mode"] for call in result["calls"]})
        },
    }
    write_json_atomic(output, result)
    print(
        f"ask evaluation: {passed_calls}/{len(result['calls'])} contract checks passed; result: {output}",
        flush=True,
    )
    return 0 if result["summary"]["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
