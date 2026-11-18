#!/usr/bin/env python3
"""Check tracked publication files. Report filenames, never matching secret text."""
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
paths = subprocess.check_output(["git", "ls-files", "-z"], cwd=ROOT).decode().split("\0")
blocked_parts = {"dist", "staging", ".build", ".tools", "__pycache__", "Desktop Profile", "IDE Profile"}
patterns = {
    "GitHub credential": re.compile(rb"(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})"),
    "private key": re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
    "Google API key": re.compile(rb"AIza[0-9A-Za-z_-]{35}"),
    "personal absolute path": re.compile(rb"/Users/(?!runner/)[A-Za-z0-9_.-]+/"),
}
failures = []
count = 0
for relative in paths:
    if not relative:
        continue
    path = Path(relative)
    if any(part in blocked_parts or part.endswith(".app") for part in path.parts) or path.name in {"session.json", ".DS_Store", ".env"} or path.suffix.lower() in {".zip", ".dmg", ".key", ".p12", ".pfx", ".log"}:
        failures.append((relative, "local artifact or private configuration"))
        continue
    full = ROOT / path
    if full.is_symlink():
        failures.append((relative, "symlinks must be reviewed before publication"))
        continue
    data = full.read_bytes()
    if len(data) > 2 * 1024 * 1024:
        failures.append((relative, "unexpected large file"))
    for label, pattern in patterns.items():
        if pattern.search(data):
            failures.append((relative, label))
    count += 1
for path, reason in failures:
    print(f"FAIL: {path}: {reason}", file=sys.stderr)
if failures:
    sys.exit(1)
print(f"Publication check passed: {count} tracked files; no blocked artifacts or detected credential patterns.")
