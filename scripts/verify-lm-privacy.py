#!/usr/bin/env python3
"""Verify successful synthetic cleanup without new LM Studio diagnostic files.

Uses only a fresh synthetic marker. Does not edit settings or existing logs.
Configure LM Studio's Developer Logs → More options through its supported UI;
editing its JSON while it runs can be overwritten by its in-memory settings.
"""
import argparse
import pathlib
import subprocess
import sys
import time
import uuid

root = pathlib.Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--benchmark", type=pathlib.Path, default=root / ".build/release/bolbhai-benchmark")
parser.add_argument("--endpoint", default="http://127.0.0.1:1234")
parser.add_argument("--cleanup-model", default="google/gemma-4-e4b")
args = parser.parse_args()
log_roots = [pathlib.Path.home() / ".lmstudio/server-logs",
             pathlib.Path.home() / ".lmstudio/.internal",
             pathlib.Path.home() / "Library/Logs/LM Studio"]

def files():
    return [p for base in log_roots for p in base.rglob("*.log") if p.is_file()]

def snapshot():
    return {str(p): (p.stat().st_size, p.stat().st_mtime_ns) for p in files()}

marker = "BolBhAI privacy sentinel " + str(uuid.uuid4().int % 100_000_000)
before = snapshot()
try:
    result = subprocess.run([str(args.benchmark), "--cleanup-text", marker,
                             "--cleanup-model", args.cleanup_model, "--endpoint", args.endpoint],
                            text=True, capture_output=True, timeout=35)
except (OSError, subprocess.TimeoutExpired) as error:
    sys.exit(f"Verification could not run: {error}")
print(result.stdout.strip())
if result.returncode or "Cleanup failed" in result.stdout:
    if result.stderr:
        print(result.stderr.strip(), file=sys.stderr)
    sys.exit("FAIL: successful cleanup is required. Check LM Studio settings/model/server first.")
time.sleep(1)
after = snapshot()
changed = sum(before.get(name) != state for name, state in after.items())
occurrences = sum(p.read_text(errors="replace").count(marker) for p in files())
print(f"Changed diagnostic files: {changed}; synthetic sentinel occurrences: {occurrences}")
if changed or occurrences:
    sys.exit("FAIL: diagnostic files changed. Investigate using synthetic text only.")
print("PASS: this synthetic request produced no new diagnostic log content.")
print("This checks the current server; rerun after LM Studio/configuration changes. Existing logs are preserved.")
