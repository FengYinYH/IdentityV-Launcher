#!/usr/bin/env python3
"""Check launcher language resources remain complete and bundle-advertised."""

from __future__ import annotations

import json
import plistlib
import re
import subprocess
import sys
from pathlib import Path


def read_strings(path: Path) -> dict[str, str]:
    encoded = subprocess.check_output(
        ["/usr/bin/plutil", "-convert", "json", "-o", "-", str(path)], text=True
    )
    value = json.loads(encoded)
    if not isinstance(value, dict) or not all(
        isinstance(key, str) and isinstance(item, str) for key, item in value.items()
    ):
        raise AssertionError(f"Expected a string table: {path}")
    return value


def main() -> int:
    source_root = Path(sys.argv[1]).resolve()
    localization_root = source_root / "Resources/Localization"
    languages = ("zh-Hans", "zh-Hant", "en")
    tables = {
        language: read_strings(localization_root / f"{language}.lproj/Localizable.strings")
        for language in languages
    }
    key_sets = {language: set(table) for language, table in tables.items()}
    reference = key_sets["zh-Hans"]
    if any(keys != reference for keys in key_sets.values()):
        detail = {language: sorted(reference ^ keys) for language, keys in key_sets.items()}
        raise AssertionError(f"Localization keys differ by language: {detail}")

    required = {
        "语言",
        "跟随系统",
        "第五人格启动器",
        "关于",
        "启动失败",
        "卸载%@？",
        "卸载游戏",
        "发送反馈",
        "麦克风未授权：游戏内语音会失败，并可能卡在「进入大厅」。请到 系统设置 → 隐私与安全性 → 麦克风 打开「第五人格启动器」后重启游戏。",
        "麦克风尚未授权：首次启动游戏时请在系统弹窗上点「允许」，否则语音会失败并可能卡在「进入大厅」。",
        "Installing %@…",
        "%@ installation complete",
        "Game installation failed: %@",
        "The installed IDV Login helper is outdated; %@",
        "版本 %@",
        "下载新版安装镜像后，退出启动器并替换应用即可。",
    }
    missing = required - reference
    if missing:
        raise AssertionError(f"Core UI translations are missing keys: {sorted(missing)}")

    source_files = (
        source_root / "Sources/IdentityVToolboxApp.swift",
        source_root / "Sources/ProductLauncherView.swift",
        source_root / "Sources/ToolboxView.swift",
        source_root / "Sources/FeedbackView.swift",
    )
    source_literals: set[str] = set()
    for source_file in source_files:
        source = source_file.read_text(encoding="utf-8")
        for match in re.finditer(r'"((?:\\.|[^"\\])*)"', source):
            literal = match.group(1).replace(r"\n", "\n")
            if not re.search(r"[\u4e00-\u9fff]", literal):
                continue
            if r"\(" in literal or literal.startswith(("/", "./")):
                continue
            source_literals.add(literal)
    unlocalized = source_literals - reference
    if unlocalized:
        raise AssertionError(f"Player UI source strings have no catalog key: {sorted(unlocalized)}")

    english = tables["en"]
    for source_key in ("第五人格启动器", "关于", "启动失败", "卸载游戏"):
        if english[source_key] == source_key:
            raise AssertionError(f"English translation is missing for {source_key!r}")
    for source_key in ("版本 %@", "下载新版安装镜像后，退出启动器并替换应用即可。"):
        if english[source_key] == source_key:
            raise AssertionError(f"English translation is missing for {source_key!r}")

    product_view = (source_root / "Sources/ProductLauncherView.swift").read_text(encoding="utf-8")
    feedback_view = (source_root / "Sources/FeedbackView.swift").read_text(encoding="utf-8")
    if 'Text("版本 \\(version)")' not in product_view:
        raise AssertionError("Expected the IDV Login version label to use its localized format key.")
    if product_view.count(".environment(\\.locale, LauncherLanguage.current.locale)") < 2:
        raise AssertionError("Launcher sheet content must explicitly inherit the selected locale.")
    if "titlePlaceholder: LocalizedStringKey" not in feedback_view or "descriptionPlaceholder: LocalizedStringKey" not in feedback_view:
        raise AssertionError("Feedback placeholders must remain localized keys, not runtime String values.")

    for language in languages:
        info_strings = read_strings(localization_root / f"{language}.lproj/InfoPlist.strings")
        if not info_strings.get("CFBundleDisplayName"):
            raise AssertionError(f"Missing localized app display name for {language}")

    with (source_root / "Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if set(info.get("CFBundleLocalizations", [])) != set(languages):
        raise AssertionError("Info.plist supported localizations do not match the resource folders")

    print(f"Localization resources passed: {len(reference)} matching keys across {len(languages)} languages.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AssertionError, OSError, subprocess.CalledProcessError) as error:
        print(f"Localization resource self-test failed: {error}", file=sys.stderr)
        raise SystemExit(1)
