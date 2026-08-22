#!/usr/bin/env python3
import argparse
import datetime as dt
import hashlib
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCENARIOS = ROOT / "tools/e2e/scenarios.json"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def command_exists(command: str) -> bool:
    if shutil.which(command) is not None:
        return True
    return (Path.home() / ".dotnet" / command).exists()


def doctor() -> int:
    checks = [
        ("swift", "macOS build"),
        ("dotnet", "Windows build"),
        ("node", "MCP build"),
        ("npm", "MCP dependencies"),
    ]
    results = [(name, command_exists(name), description) for name, description in checks]
    for name, present, description in results:
        state = "ok" if present else "missing"
        print(f"{state:7} {name:8} {description}")
    return 0 if all(present for _, present, _ in results) else 1


def make_file(path: Path, content: bytes, root: Path) -> dict:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(content)
    return {
        "relative_path": path.relative_to(root).as_posix(),
        "size": len(content),
        "sha256": sha256(path),
    }


def fixture(profile: str, output: Path) -> int:
    if output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True)
    entries = []

    text = (
        "Sticky UTF-8 probe\n"
        "Accents: áéíóú\nEmoji: ✅ 🚀 🧲\nQuotes: \"single' double\"\n"
        "Code: {\"strict\": true, \"line\": 1}\n"
    ).encode()
    entries.append(make_file(output / "clipboard.txt", text, output))
    png = bytes.fromhex(
        "89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c489"
        "0000000d49444154789c626001000000ffff03000006000557bfabd40000000049454e44ae426082"
    )
    entries.append(make_file(output / "images/tiny.png", png, output))
    entries.append(make_file(output / "documents/report.txt", b"release report\n", output))
    entries.append(make_file(output / "nested/deep/file with spaces.txt", b"spaces preserved\n", output))
    (output / "empty-folder").mkdir()

    if profile == "large":
        sparse_path = output / "large/sparse.bin"
        sparse_path.parent.mkdir(parents=True, exist_ok=True)
        size = 500 * 1024 * 1024 * 1024
        with sparse_path.open("wb") as handle:
            handle.truncate(size)
            for offset in (0, size // 2, max(0, size - 1024 * 1024)):
                handle.seek(offset)
                handle.write(os.urandom(1024 * 1024))
        entries.append(
            {
                "relative_path": sparse_path.relative_to(output).as_posix(),
                "size": size,
                "sparse": True,
                "sample_size": 1024 * 1024,
                "note": "Compare head/middle/tail samples rather than hashing the full file.",
            }
        )

    manifest = {
        "version": 1,
        "profile": profile,
        "created_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        "files": entries,
        "expected_directories": ["images", "documents", "nested/deep", "empty-folder"],
    }
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Created {profile} fixtures in {output}")
    return 0


def resolve_destination(destination: Path, relative_path: str) -> list[Path]:
    parent = destination.parent
    stem = destination.name
    candidates = [destination]
    for counter in range(2, 101):
        candidates.append(parent / f"{stem} ({counter})" / relative_path)
    return candidates


def verify(manifest_path: Path, destination: Path) -> int:
    manifest = json.loads(manifest_path.read_text())
    missing = []
    mismatched = []
    checked = 0
    source_root = manifest_path.parent
    for entry in manifest["files"]:
        relative = entry["relative_path"]
        source = source_root / relative
        matches = [candidate for candidate in resolve_destination(destination, relative) if candidate.exists()]
        if not matches:
            missing.append(relative)
            continue
        actual = matches[0]
        checked += 1
        if actual.stat().st_size != entry["size"]:
            mismatched.append({"path": relative, "reason": "size"})
        elif not entry.get("sparse") and sha256(actual) != entry["sha256"]:
            mismatched.append({"path": relative, "reason": "hash"})
    result = {
        "checked": checked,
        "missing": missing,
        "mismatched": mismatched,
        "passed": not missing and not mismatched,
    }
    print(json.dumps(result, indent=2))
    return 0 if result["passed"] else 1


def load_cases() -> dict[str, dict]:
    data = json.loads(SCENARIOS.read_text())
    return {case["id"]: case for case in data["cases"]}


def record(run_dir: Path, case_id: str, status: str, evidence: list[Path], notes: str) -> int:
    cases = load_cases()
    if case_id not in cases:
        raise SystemExit(f"Unknown case: {case_id}")
    if status not in {"pass", "fail", "blocked"}:
        raise SystemExit("Status must be pass, fail, or blocked")
    run_dir.mkdir(parents=True, exist_ok=True)
    copied_evidence = []
    evidence_dir = run_dir / "evidence"
    evidence_dir.mkdir(exist_ok=True)
    for item in evidence:
        target = evidence_dir / item.name
        shutil.copy2(item, target)
        copied_evidence.append(str(target.relative_to(run_dir)))
    event = {
        "case": case_id,
        "title": cases[case_id]["title"],
        "status": status,
        "notes": notes,
        "evidence": copied_evidence,
        "recorded_at": dt.datetime.now(dt.timezone.utc).isoformat(),
    }
    with (run_dir / "results.jsonl").open("a") as handle:
        handle.write(json.dumps(event, sort_keys=True) + "\n")
    print(json.dumps(event, indent=2))
    return 0


def report(run_dir: Path) -> int:
    cases = load_cases()
    results = {case_id: "not_run" for case_id in cases}
    results_path = run_dir / "results.jsonl"
    if results_path.exists():
        for line in results_path.read_text().splitlines():
            if line.strip():
                event = json.loads(line)
                results[event["case"]] = event["status"]
    counts = {status: list(results.values()).count(status) for status in ("pass", "fail", "blocked", "not_run")}
    summary = {
        "run_dir": str(run_dir),
        "total_cases": len(cases),
        "counts": counts,
        "cases": results,
        "release_ready": counts["pass"] == len(cases),
    }
    output = run_dir / "report.json"
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))
    return 0 if summary["release_ready"] else 1


def main() -> int:
    parser = argparse.ArgumentParser(description="Sticky end-to-end QA harness")
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("doctor")

    fixture_parser = subparsers.add_parser("fixture")
    fixture_parser.add_argument("--profile", choices=("standard", "large"), default="standard")
    fixture_parser.add_argument("--output", type=Path, required=True)

    verify_parser = subparsers.add_parser("verify")
    verify_parser.add_argument("--manifest", type=Path, required=True)
    verify_parser.add_argument("--destination", type=Path, required=True)

    record_parser = subparsers.add_parser("record")
    record_parser.add_argument("--run-dir", type=Path, required=True)
    record_parser.add_argument("--case", required=True)
    record_parser.add_argument("--status", required=True)
    record_parser.add_argument("--evidence", type=Path, nargs="*", default=[])
    record_parser.add_argument("--notes", default="")

    report_parser = subparsers.add_parser("report")
    report_parser.add_argument("--run-dir", type=Path, required=True)

    args = parser.parse_args()
    if args.command == "doctor":
        return doctor()
    if args.command == "fixture":
        return fixture(args.profile, args.output)
    if args.command == "verify":
        return verify(args.manifest, args.destination)
    if args.command == "record":
        return record(args.run_dir, args.case, args.status, args.evidence, args.notes)
    return report(args.run_dir)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("Interrupted", file=sys.stderr)
        raise SystemExit(130)
