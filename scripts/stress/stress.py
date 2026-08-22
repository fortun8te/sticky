#!/usr/bin/env python3
"""Deterministic local stress fixtures and transfer simulations for Sticky."""

import argparse
import hashlib
import json
import os
import re
import shutil
import sys
import threading
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path


TOOL_VERSION = "1.0.0"
REPORT_SCHEMA_VERSION = 1
CHUNK_SIZE = 64 * 1024
SPARSE_INTERVAL = 4 * 1024 * 1024
HASH_READ_SIZE = 1024 * 1024
SCENARIOS = (
    "batch-1",
    "batch-10",
    "batch-100",
    "batch-500",
    "interrupted",
    "duplicates",
    "unicode-spaces",
    "zero-byte",
    "huge-single",
    "concurrent",
)
PROFILE_SCENARIOS = {
    "smoke": (
        "batch-1",
        "batch-10",
        "interrupted",
        "duplicates",
        "unicode-spaces",
        "zero-byte",
        "concurrent",
    ),
    "standard": SCENARIOS[:-1],
    "all": SCENARIOS,
}


class StressError(Exception):
    pass


def parse_size(value):
    match = re.fullmatch(r"(?i)\s*(\d+(?:\.\d+)?)\s*([kmgt]?i?b?)\s*", str(value))
    if not match:
        raise argparse.ArgumentTypeError("size must look like 1KB, 10MB, 2GB, or 1073741824")
    number = float(match.group(1))
    unit = match.group(2).lower().rstrip("b")
    multipliers = {"": 1, "k": 1024, "ki": 1024, "m": 1024**2, "mi": 1024**2,
                   "g": 1024**3, "gi": 1024**3, "t": 1024**4, "ti": 1024**4}
    if unit not in multipliers:
        raise argparse.ArgumentTypeError(f"unsupported size unit: {match.group(2)}")
    result = int(number * multipliers[unit])
    if result < 0:
        raise argparse.ArgumentTypeError("size cannot be negative")
    return result


def human_size(size):
    value = float(size)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if value < 1024 or unit == "TB":
            return f"{value:.0f}{unit}" if unit == "B" else f"{value:.1f}{unit}"
        value /= 1024


def canonical_relpath(value):
    path = Path(value)
    if path.is_absolute() or any(part in ("", ".", "..") for part in path.parts):
        raise StressError(f"unsafe relative path: {value}")
    return Path(*path.parts)


def stable_digest(value):
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def deterministic_session_id(scenario, index):
    return stable_digest(f"sticky-stress-v1:{scenario}:{index}")[:8] + "-" + \
        stable_digest(f"session:{scenario}:{index}")[8:12] + "-4" + \
        stable_digest(f"v4:{scenario}:{index}")[13:15] + "-a" + \
        stable_digest(f"variant:{scenario}:{index}")[16:19] + "-" + \
        stable_digest(f"node:{scenario}:{index}")[20:32]


def deterministic_block(seed, block_index):
    material = f"{seed}:{block_index}".encode("utf-8")
    output = bytearray()
    counter = 0
    while len(output) < CHUNK_SIZE:
        output.extend(hashlib.sha256(material + b":" + str(counter).encode()).digest())
        counter += 1
    return bytes(output[:CHUNK_SIZE])


def write_payload(path, relpath, size, sparse=True):
    path.parent.mkdir(parents=True, exist_ok=True)
    seed = stable_digest(str(relpath))
    if size == 0:
        path.write_bytes(b"")
        return
    if not sparse or size <= SPARSE_INTERVAL:
        with path.open("wb") as handle:
            remaining = size
            block_index = 0
            while remaining:
                block = deterministic_block(seed, block_index)
                chunk = block[:min(CHUNK_SIZE, remaining)]
                handle.write(chunk)
                remaining -= len(chunk)
                block_index += 1
        return
    offsets = list(range(0, size, SPARSE_INTERVAL))
    if offsets[-1] != size - 1:
        offsets.append(size - 1)
    with path.open("wb") as handle:
        for offset in offsets:
            block_index = offset // CHUNK_SIZE
            block_offset = offset % CHUNK_SIZE
            block = deterministic_block(seed, block_index)[block_offset:]
            handle.seek(offset)
            handle.write(block[: min(len(block), SPARSE_INTERVAL)])
        handle.truncate(size)


def sha256_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while True:
            chunk = handle.read(HASH_READ_SIZE)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def fixture_entry(root, relpath, size, sparse=True):
    relative = canonical_relpath(relpath)
    target = root / "source" / relative
    write_payload(target, relative, size, sparse=sparse)
    return {
        "id": "",
        "mime": "application/octet-stream",
        "path": relative.as_posix(),
        "sha256": sha256_file(target),
        "size": size,
        "sparse": bool(sparse and size > SPARSE_INTERVAL),
    }


def batch_entries(root, scenario, count, size=1024):
    entries = []
    per_dir = max(1, count // 10) if count > 10 else count
    for index in range(count):
        directory = index // per_dir
        name = "single.dat" if count == 1 else f"file-{index:04d}.dat"
        relpath = name if directory == 0 else f"group-{directory:02d}/{name}"
        entry = fixture_entry(root, Path(scenario) / relpath, size)
        entry["id"] = f"f{index + 1}"
        entries.append(entry)
    return entries


def interrupted_entries(root):
    specs = (("parts/alpha.bin", 256 * 1024, 25), ("parts/beta.bin", 512 * 1024, 60),
             ("parts/gamma.bin", 1024 * 1024, 10))
    entries = []
    for index, (relpath, size, percent) in enumerate(specs):
        entry = fixture_entry(root, Path("interrupted") / relpath, size, sparse=False)
        entry.update(id=f"f{index + 1}", interrupt_after_percent=percent)
        entries.append(entry)
    return entries


def duplicate_entries(root):
    paths = (
        "reports/final/report.pdf", "nested/deep/reports/final/report.pdf",
        "same-name/photo.jpg", "other/photo.jpg",
    )
    entries = []
    generated = {}
    output = []
    file_number = 1
    for repeat in range(3):
        for relpath in paths:
            if (repeat, relpath) == (0, "nested/deep/reports/final/report.pdf"):
                continue
            key = relpath if relpath not in generated else None
            if key is not None:
                source_relpath = Path("duplicates") / relpath
                generated[relpath] = fixture_entry(root, source_relpath, 2048)
            entry = dict(generated[relpath])
            entry["id"] = f"f{file_number}"
            entry["duplicate_of_path"] = relpath
            output.append(entry)
            file_number += 1
    return output


def unicode_entries(root):
    paths = (
        "résumés/curriculum vitae.docx", "中文 文件/图片 照片.png",
        "emoji folder/🎉 party plan.md", "naïve café/note.txt",
    )
    entries = []
    for index, relpath in enumerate(paths):
        entry = fixture_entry(root, Path("unicode-spaces") / relpath, 4096, sparse=False)
        entry["id"] = f"f{index + 1}"
        entries.append(entry)
    return entries


def build_scenario_entries(root, scenario, args):
    if scenario.startswith("batch-"):
        count = int(scenario.split("-")[1])
        return batch_entries(root, scenario, count, parse_size(args.batch_file_size))
    if scenario == "interrupted":
        return interrupted_entries(root)
    if scenario == "duplicates":
        return duplicate_entries(root)
    if scenario == "unicode-spaces":
        return unicode_entries(root)
    if scenario == "zero-byte":
        entries = []
        paths = ("empty.dat", "folder/also-empty.bin", "deep/path/nothing.txt")
        for index, relpath in enumerate(paths):
            entry = fixture_entry(root, Path("zero-byte") / relpath, 0, sparse=False)
            entry["id"] = f"f{index + 1}"
            entries.append(entry)
        return entries
    if scenario == "huge-single":
        entry = fixture_entry(root, "huge-single/giant-sparse.bin", args.huge_size, sparse=not args.huge_dense)
        entry["id"] = "f1"
        entry["upload_mode"] = args.huge_mode
        return [entry]
    if scenario == "concurrent":
        raise RuntimeError("concurrent sessions are assembled separately")
    raise StressError(f"unknown scenario: {scenario}")


def write_json(path, payload):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="\n") as handle:
        json.dump(payload, handle, ensure_ascii=False, indent=2, sort_keys=True)
        handle.write("\n")


def manifest_for(scenario, entries):
    return {
        "schema_version": REPORT_SCHEMA_VERSION,
        "scenario": scenario,
        "algorithm": "sha256",
        "file_count": len(entries),
        "total_bytes": sum(entry["size"] for entry in entries),
        "files": entries,
    }


def install_file(source, destination, mode="copy"):
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.parent / (destination.name + ".stress-partial")
    if temporary.exists():
        temporary.unlink()
    if mode == "hardlink":
        os.link(source, temporary)
    elif mode == "clone":
        result = os.system(f"cp -c {shlex_quote(str(source))} {shlex_quote(str(temporary))}")
        if result != 0:
            shutil.copyfile(source, temporary)
    else:
        with source.open("rb") as source_handle, temporary.open("wb") as target_handle:
            while True:
                chunk = source_handle.read(CHUNK_SIZE)
                if not chunk:
                    break
                target_handle.write(chunk)
    return temporary


def shlex_quote(value):
    return "'" + str(value).replace("'", "'\\''") + "'"


class Receiver:
    def __init__(self, received_root):
        self.received_root = received_root
        self.lock = threading.Lock()

    def finalize(self, staging_file, requested_path, upload_mode):
        relative = canonical_relpath(requested_path)
        with self.lock:
            destination = self.received_root / relative
            candidate = destination
            counter = 2
            while candidate.exists():
                candidate = destination.with_name(f"{destination.stem} ({counter}){destination.suffix}")
                counter += 1
            candidate.parent.mkdir(parents=True, exist_ok=True)
            os.replace(staging_file, candidate)
            return candidate.relative_to(self.received_root).as_posix()


def copy_interrupted_prefix(source, target, limit):
    target.parent.mkdir(parents=True, exist_ok=True)
    copied = 0
    with source.open("rb") as source_handle, target.open("wb") as target_handle:
        while copied < limit:
            chunk = source_handle.read(min(CHUNK_SIZE, limit - copied))
            if not chunk:
                break
            target_handle.write(chunk)
            copied += len(chunk)
    return copied


def verify_prefix(source, partial, byte_count):
    digest = hashlib.sha256()
    with source.open("rb") as expected_handle, partial.open("rb") as actual_handle:
        remaining = byte_count
        while remaining:
            expected = expected_handle.read(min(HASH_READ_SIZE, remaining))
            actual = actual_handle.read(min(HASH_READ_SIZE, remaining))
            if expected != actual:
                return False, digest.hexdigest()
            digest.update(actual)
            remaining -= len(expected)
    return True, digest.hexdigest()


def check(condition, checks, name, details=None):
    checks.append({"name": name, "status": "passed" if condition else "failed", **(details or {})})
    return condition


def run_upload_session(receiver, scenario_name, session_index, entries, session_root, source_root):
    session_id = deterministic_session_id(scenario_name, session_index)
    session_dir = session_root / session_id
    staging_dir = session_dir / "staging"
    staging_dir.mkdir(parents=True, exist_ok=True)
    tokens = {entry["id"]: stable_digest(f"{session_id}:{entry['id']}") for entry in entries}
    prepare = {
        "session": session_id,
        "kind": "files",
        "sender": {"id": stable_digest("stress-sender"), "name": "Sticky Stress Sender"},
        "files": [{key: entry[key] for key in ("id", "path", "size", "mime")} for entry in entries],
    }
    write_json(session_dir / "prepare-upload.json", prepare)
    write_json(session_dir / "tokens.json", {"session": session_id, "tokens": tokens})

    received = []
    interrupted = []
    checks = []
    for entry in entries:
        source = source_root / entry["path"]
        token = tokens[entry["id"]]
        staging = staging_dir / f"{entry['id']}.bin"
        if entry.get("interrupt_after_percent"):
            limit = max(1, entry["size"] * entry["interrupt_after_percent"] // 100)
            uploaded = copy_interrupted_prefix(source, staging, limit)
            prefix_matches, partial_hash = verify_prefix(source, staging, uploaded)
            check(prefix_matches, checks, f"prefix-integrity:{entry['id']}",
                  {"bytes": uploaded, "partial_sha256": partial_hash})
            interrupted.append({
                "file_id": entry["id"], "path": entry["path"], "expected_size": entry["size"],
                "uploaded_bytes": uploaded, "uploaded_sha256": partial_hash,
                "status": "interrupted",
            })
            continue
        install_file(source, staging, entry.get("upload_mode", "copy"))
        actual_hash = sha256_file(staging)
        valid = check(actual_hash == entry["sha256"], checks, f"upload-sha256:{entry['id']}",
                      {"expected_sha256": entry["sha256"], "actual_sha256": actual_hash})
        if not valid:
            continue
        stored_path = receiver.finalize(staging, entry["path"], entry.get("upload_mode", "copy"))
        received.append({"file_id": entry["id"], "requested_path": entry["path"], "received_path": stored_path})

    complete_response = {"session": session_id, "received": [item["received_path"] for item in received]}
    write_json(session_dir / "complete-response.json", complete_response)
    return {
        "session": session_id, "prepared_files": len(entries), "received_files": received,
        "interrupted_files": interrupted, "checks": checks,
    }


def verify_received(received_root, received_items, entries_by_id, checks):
    for item in received_items:
        path = received_root / item["received_path"]
        exists = path.is_file()
        check(exists, checks, f"received-exists:{item['file_id']}", {"path": item["received_path"]})
        if not exists:
            continue
        actual_hash = sha256_file(path)
        expected = entries_by_id[item["file_id"]]["sha256"]
        check(actual_hash == expected, checks, f"received-sha256:{item['file_id']}",
              {"expected_sha256": expected, "actual_sha256": actual_hash})


def scenario_result(name, status, entries, checks, extra=None):
    passed = sum(item["status"] == "passed" for item in checks)
    failed = len(checks) - passed
    result = {
        "scenario": name, "status": status, "file_count": len(entries),
        "total_bytes": sum(entry["size"] for entry in entries),
        "checks_total": len(checks), "checks_passed": passed, "checks_failed": failed,
    }
    result.update(extra or {})
    return result


def run_regular_scenario(scenario, root, args):
    scenario_root = root / "runs" / scenario
    if scenario_root.exists():
        shutil.rmtree(scenario_root)
    source_root = scenario_root / "source"
    entries = build_scenario_entries(source_root, scenario, args)
    manifest = manifest_for(scenario, entries)
    manifest_path = scenario_root / "manifest.json"
    write_json(manifest_path, manifest)
    receiver = Receiver(scenario_root / "received")
    sessions = [run_upload_session(receiver, scenario, 1, entries, scenario_root / "sessions", source_root)]
    entries_by_id = {entry["id"]: entry for entry in entries}
    checks = []
    for session in sessions:
        verify_received(receiver.received_root, session["received_files"], entries_by_id, checks)
        checks.extend(session["checks"])
    if scenario == "duplicates":
        expected_names = {"report (2).pdf", "report (3).pdf"}
        actual_names = {Path(item["received_path"]).name for item in sessions[0]["received_files"]}
        check(expected_names.issubset(actual_names), checks, "collision-safe-names",
              {"expected_subset": sorted(expected_names), "actual": sorted(actual_names)})
    failed = any(item["status"] == "failed" for item in checks)
    result = scenario_result(scenario, "failed" if failed else "passed", entries, checks, {
        "manifest": manifest_path.relative_to(root).as_posix(),
        "sessions": sessions,
        "received_count": sum(len(session["received_files"]) for session in sessions),
        "interrupted_count": sum(len(session["interrupted_files"]) for session in sessions),
    })
    return result, failed


def concurrent_worker(worker_index, root, args):
    scenario_root = root / "runs" / "concurrent"
    source_root = scenario_root / f"session-source-{worker_index}"
    entries = batch_entries(source_root, f"concurrent-{worker_index}", args.concurrent_files_per_session)
    write_json(scenario_root / f"manifest-session-{worker_index}.json", manifest_for(f"concurrent-{worker_index}", entries))
    receiver = Receiver(scenario_root / "received")
    return worker_index, run_upload_session(
        receiver, "concurrent", worker_index, entries, scenario_root / "sessions", source_root
    ), entries


def run_concurrent_scenario(root, args):
    scenario = "concurrent"
    scenario_root = root / "runs" / scenario
    if scenario_root.exists():
        shutil.rmtree(scenario_root)
    results = {}
    all_checks = []
    with ThreadPoolExecutor(max_workers=args.concurrent_sessions) as executor:
        futures = [executor.submit(concurrent_worker, index, root, args)
                   for index in range(args.concurrent_sessions)]
        for future in as_completed(futures):
            index, session, entries = future.result()
            results[index] = (session, entries)
            all_checks.extend(session["checks"])
    ordered_sessions = []
    total_entries = []
    entries_by_id = {}
    for index in range(args.concurrent_sessions):
        session, entries = results[index]
        local_entries = [dict(entry) for entry in entries]
        for entry in local_entries:
            entry["id"] = f"s{index}-{entry['id']}"
        session = dict(session)
        session["received_files"] = [dict(item, file_id=f"s{index}-{item['file_id']}") for item in session["received_files"]]
        ordered_sessions.append(session)
        total_entries.extend(local_entries)
        for entry in local_entries:
            entries_by_id[entry["id"]] = entry
    checks = []
    receiver_root = scenario_root / "received"
    for session in ordered_sessions:
        verify_received(receiver_root, session["received_files"], entries_by_id, checks)
    checks.extend(all_checks)
    failed = any(item["status"] == "failed" for item in checks)
    result = scenario_result(scenario, "failed" if failed else "passed", total_entries, checks, {
        "manifests": [f"manifest-session-{index}.json" for index in range(args.concurrent_sessions)],
        "sessions": ordered_sessions,
        "concurrent_sessions": args.concurrent_sessions,
        "received_count": sum(len(session["received_files"]) for session in ordered_sessions),
    })
    return result, failed


def verify_manifest(root, manifest_path):
    with manifest_path.open(encoding="utf-8") as handle:
        manifest = json.load(handle)
    checks = []
    base = manifest_path.parent
    for entry in manifest["files"]:
        source = base / "source" / entry["path"]
        exists = source.is_file()
        check(exists, checks, f"exists:{entry['id']}", {"path": entry["path"]})
        if not exists:
            continue
        actual_size = source.stat().st_size
        check(actual_size == entry["size"], checks, f"size:{entry['id']}",
              {"expected": entry["size"], "actual": actual_size})
        actual_hash = sha256_file(source)
        check(actual_hash == entry["sha256"], checks, f"sha256:{entry['id']}",
              {"expected_sha256": entry["sha256"], "actual_sha256": actual_hash})
    return checks


def command_generate(args):
    root = args.root.resolve()
    if root.exists() and any(root.iterdir()) and not args.force:
        raise StressError(f"output root is not empty: {args.root} (use --force)")
    if args.force and root.exists():
        shutil.rmtree(root)
    entries = batch_entries(root, "generated", args.count, args.size)
    manifest_path = root / "manifest.json"
    write_json(manifest_path, manifest_for("generated", entries))
    print(manifest_path)


def command_verify(args):
    root = args.root.resolve()
    manifests = [root / "manifest.json"] if args.manifest else sorted((root / "runs").glob("*/manifest*.json"))
    if not manifests:
        raise StressError(f"no manifests found under: {root}")
    aggregate = []
    failed = False
    for manifest in manifests:
        checks = verify_manifest(root, manifest)
        failed |= any(item["status"] == "failed" for item in checks)
        aggregate.append({"manifest": manifest.relative_to(root).as_posix(),
                          "checks": checks,
                          "status": "failed" if any(i["status"] == "failed" for i in checks) else "passed"})
    report = {"schema_version": REPORT_SCHEMA_VERSION, "tool_version": TOOL_VERSION,
              "command": "verify", "root": str(root), "results": aggregate}
    report_path = root / "verify-report.json"
    write_json(report_path, report)
    print(report_path)
    return 1 if failed else 0


def select_scenarios(args):
    profile_scenarios = PROFILE_SCENARIOS[args.profile]
    if args.only:
        requested = [value.strip() for value in args.only.split(",") if value.strip()]
        unknown = [value for value in requested if value not in SCENARIOS]
        if unknown:
            raise StressError(f"unknown scenarios: {', '.join(unknown)}")
        return requested
    return list(profile_scenarios)


def command_run(args):
    root = args.root.resolve()
    scenarios = select_scenarios(args)
    if root.exists() and any(root.iterdir()) and not args.force:
        raise StressError(f"output root is not empty: {args.root} (use --force)")
    if args.force and root.exists():
        shutil.rmtree(root)
    root.mkdir(parents=True, exist_ok=True)
    config = {
        "profile": args.profile, "scenarios": scenarios, "chunk_size": CHUNK_SIZE,
        "batch_file_size": args.batch_file_size, "batch_file_size_human": human_size(parse_size(args.batch_file_size)),
        "huge_size": parse_size(args.huge_size), "huge_size_human": human_size(parse_size(args.huge_size)),
        "huge_mode": args.huge_mode, "huge_dense": args.huge_dense,
        "concurrent_sessions": args.concurrent_sessions,
        "concurrent_files_per_session": args.concurrent_files_per_session,
    }
    results = []
    failed = False
    for scenario in scenarios:
        if scenario == "concurrent":
            result, failure = run_concurrent_scenario(root, args)
        else:
            result, failure = run_regular_scenario(scenario, root, args)
        results.append(result)
        failed |= failure
        print(f"{scenario}: {result['status']} ({result['checks_passed']}/{result['checks_total']} checks)")
    summary = {
        "scenarios_total": len(results), "scenarios_passed": sum(r["status"] == "passed" for r in results),
        "scenarios_failed": sum(r["status"] == "failed" for r in results),
        "checks_total": sum(r["checks_total"] for r in results),
        "checks_passed": sum(r["checks_passed"] for r in results),
        "checks_failed": sum(r["checks_failed"] for r in results),
    }
    report = {"schema_version": REPORT_SCHEMA_VERSION, "tool_version": TOOL_VERSION,
              "command": "run", "config": config, "root": str(root),
              "summary": summary, "scenarios": results}
    report_path = root / "stress-report.json"
    write_json(report_path, report)
    print(report_path)
    return 1 if failed else 0


def parser():
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    run_parser = subparsers.add_parser("run", help="generate fixtures and simulate protocol uploads")
    run_parser.add_argument("--root", type=Path, required=True, help="empty output directory")
    run_parser.add_argument("--profile", choices=tuple(PROFILE_SCENARIOS), default="standard")
    run_parser.add_argument("--only", help="comma-separated scenario names; overrides --profile")
    run_parser.add_argument("--force", action="store_true", help="replace an existing output root")
    run_parser.add_argument("--batch-file-size", type=str, default="1KB")
    run_parser.add_argument("--huge-size", type=str, default="1GB")
    run_parser.add_argument("--huge-mode", choices=("copy", "clone", "hardlink"), default="copy")
    run_parser.add_argument("--huge-dense", action="store_true", help="write every byte instead of using a sparse payload")
    run_parser.add_argument("--concurrent-sessions", type=int, default=4)
    run_parser.add_argument("--concurrent-files-per-session", type=int, default=5)
    run_parser.set_defaults(function=command_run)

    generate_parser = subparsers.add_parser("generate", help="generate one deterministic folder tree")
    generate_parser.add_argument("--root", type=Path, required=True)
    generate_parser.add_argument("--count", type=int, default=10)
    generate_parser.add_argument("--size", type=parse_size, default=1024)
    generate_parser.add_argument("--force", action="store_true")
    generate_parser.set_defaults(function=command_generate)

    verify_parser = subparsers.add_parser("verify", help="re-hash every file listed by found manifests")
    verify_parser.add_argument("--root", type=Path, required=True)
    verify_parser.add_argument("--manifest", action="store_true", help="verify root manifest only")
    verify_parser.set_defaults(function=command_verify)
    return parser


def main(argv=None):
    parsed = parser().parse_args(argv)
    try:
        return parsed.function(parsed)
    except (OSError, StressError, RuntimeError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
