#!/usr/bin/env python3
"""A narrow reproducible exact-line comparison; not an authorship/legal test."""
import argparse
import difflib
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument("upstream", type=Path, help="checkout of the audited upstream commit")
parser.add_argument("--revision", default="11786f7", help="local tracked-source revision")
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
paths = subprocess.check_output(["git", "ls-tree", "-r", "--name-only", args.revision], cwd=root, text=True).splitlines()
paths = [p for p in paths if Path(p).suffix in (".py", ".go", ".swift", ".sh")]
upstream = list((args.upstream / "src").rglob("*.py"))
matches = 0
for path in paths:
    text = subprocess.check_output(["git", "show", f"{args.revision}:{path}"], cwd=root, text=True)
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    for other in upstream:
        theirs = [line.strip() for line in other.read_text().splitlines() if line.strip()]
        block = difflib.SequenceMatcher(None, lines, theirs, autojunk=True).find_longest_match()
        if block.size >= 5:
            matches += 1
            print(path, other.relative_to(args.upstream), block.size)
print(f"localFiles={len(paths)} upstreamFiles={len(upstream)} fiveLineMatches={matches}")
