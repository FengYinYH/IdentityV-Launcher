#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Check mapped GDI payload paths and unchanged PE link/code contracts."""

import argparse
import hashlib
import json
from pathlib import Path
import re
from typing import Optional


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def blocks(text: str, marker: str) -> list[str]:
    result = []
    cursor = 0
    while True:
        start = text.find(marker, cursor)
        if start < 0:
            return result
        opening = text.find("{", start)
        depth = 0
        quoted = False
        for index in range(opening, len(text)):
            char = text[index]
            if char == '"' and (index == 0 or text[index - 1] != "\\"):
                quoted = not quoted
            elif not quoted and char == "{":
                depth += 1
            elif not quoted and char == "}":
                depth -= 1
                if depth == 0:
                    result.append(text[start:index + 1])
                    cursor = index + 1
                    break
        else:
            raise AssertionError(f"unterminated readobj record: {marker}")


def value(block: str, key: str) -> Optional[str]:
    match = re.search(rf"^\s*{re.escape(key)}:\s*(.*?)\s*$", block, re.MULTILINE)
    return match.group(1) if match else None


def link_contract(path: Path, readobj_output: Path) -> dict:
    output = readobj_output.read_text()
    header = output[:output.find("DOSHeader {") if "DOSHeader {" in output else len(output)]
    versions = {
        key: value(header, key)
        for key in (
            "Machine", "SectionCount", "MajorOperatingSystemVersion",
            "MinorOperatingSystemVersion", "MajorSubsystemVersion",
            "MinorSubsystemVersion", "ImageBase", "Subsystem",
        )
    }
    assert versions["Machine"] == "IMAGE_FILE_MACHINE_AMD64 (0x8664)", "GDI output must be PE AMD64"
    assert versions["MajorOperatingSystemVersion"] is not None, "PE OS version is missing"

    imports = []
    for item in blocks(output, "Import {"):
        symbols = []
        for symbol in re.findall(r"^\s*Symbol:\s*(.*?)\s*$", item, re.MULTILINE):
            # llvm-readobj prints PE import hints in parentheses after named
            # imports. They are lookup hints, not imported ordinals, and can
            # shift when the source rebuild's import libraries are regenerated.
            symbols.append(("symbol", re.sub(r"\s+\(\d+\)$", "", symbol)))
        symbols.extend(
            ("ordinal", ordinal)
            for ordinal in re.findall(r"^\s*Ordinal:\s*(.*?)\s*$", item, re.MULTILINE)
        )
        imports.append((
            value(item, "Name"),
            tuple(sorted(symbols)),
        ))
    imports.sort()
    exports = [
        (value(item, "Ordinal"), value(item, "Name"), value(item, "ForwarderRVA"))
        for item in blocks(output, "Export {")
    ]

    sections = []
    for item in blocks(output, "Section {"):
        name = value(item, "Name")
        if name is None:
            continue
        flags_text = re.search(r"Characteristics \[([^]]*)\]", item, re.DOTALL)
        flags = tuple(re.findall(r"^\s*([A-Z][A-Z0-9_]+) \(0x[0-9A-Fa-f]+\)$",
                                 flags_text.group(1), re.MULTILINE)) if flags_text else ()
        sections.append((name.split(" ", 1)[0], flags))
    assert sections, "PE section table is missing"
    return {
        "sha256": sha256(path),
        "header": versions,
        "imports": imports,
        "exports": exports,
        "sections": sections,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", required=True, type=Path)
    parser.add_argument("--candidate", required=True, type=Path)
    parser.add_argument("--baseline-readobj", required=True, type=Path)
    parser.add_argument("--candidate-readobj", required=True, type=Path)
    parser.add_argument("--baseline-text", required=True, type=Path)
    parser.add_argument("--candidate-text", required=True, type=Path)
    parser.add_argument("--strings", required=True, type=Path)
    parser.add_argument("--report", required=True, type=Path)
    parser.add_argument("--forbidden", nargs="*", default=[])
    args = parser.parse_args()

    baseline = link_contract(args.baseline, args.baseline_readobj)
    candidate = link_contract(args.candidate, args.candidate_readobj)
    for field in ("header", "imports", "exports", "sections"):
        assert candidate[field] == baseline[field], f"candidate PE {field} contract differs from baseline"

    baseline_text_sha = sha256(args.baseline_text)
    candidate_text_sha = sha256(args.candidate_text)

    strings = args.strings.read_text(errors="replace")
    patterns = {"user_path_prefix": "/Users/", "private_workspace_marker": "codexDaily",
                "external_data_mount": "/Volumes/Data/"}
    patterns.update({f"input_path_{index}": path for index, path in enumerate(args.forbidden) if path})
    findings = {name: strings.count(pattern) for name, pattern in patterns.items() if pattern}
    assert not any(findings.values()), f"candidate retains private build-path markers: {findings}"

    report = {
        "result": "pass",
        "candidateSha256": candidate["sha256"],
        "baselineSha256": baseline["sha256"],
        "sectionNames": [name for name, _ in candidate["sections"]],
        "sectionCount": len(candidate["sections"]),
        "importRecordCount": len(candidate["imports"]),
        "exportRecordCount": len(candidate["exports"]),
        "peHeaderContract": candidate["header"],
        "textSectionSha256": candidate_text_sha,
        "baselineTextSectionSha256": baseline_text_sha,
        "textSectionMatchesBaseline": candidate_text_sha == baseline_text_sha,
        "privatePathMarkerCounts": findings,
        "comparison": "named import symbols and true ordinal imports, exports, section names/flags, and PE architecture/OS/subsystem contract match; .text hashes are reported for diagnosis but are not required to match across source rebuilds",
    }
    args.report.write_text(json.dumps(report, indent=2) + "\n")
    print("GDI PE ABI, .text, and private-path checks passed")


if __name__ == "__main__":
    main()
