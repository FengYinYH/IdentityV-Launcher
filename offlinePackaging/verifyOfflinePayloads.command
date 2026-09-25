#!/bin/zsh
# verifyOfflinePayloads.command — 独立复核「离线整包」里到底带了什么，以及它们是不是锁定的那份字节。
#
# 为什么单独成一个脚本：这套检查要在两处跑同一份逻辑——签名之前检查打入 App 的载荷，
# 以及 DMG 只读挂载之后再检查一次。只跑前面那次不能证明字节真的穿过了 DMG 生成和压缩，
# 所以同一条命令要在两个时点给出可比的结论。
#
# 检查两件事：
#   1. 三个上游组件都在，且与 offlinePayloads.json、以及三份发行清单正本逐字节一致；
#   2. 白名单之外不存在任何游戏 payload（.exe/.dll/.pak/.ucas/.utoc），也就是「除了游戏，其他都带」，
#      但绝不包括游戏本体。
#
# 用法：./offlinePackaging/verifyOfflinePayloads.command --app ABS/第五人格启动器.app
set -euo pipefail

script_dir="${0:A:h}"
project_root="${script_dir:h}"

runtime_manifest="$project_root/runtimeBootstrap/runtime-manifest.json"
core_manifest="$project_root/downloaderCoreComponent.json"
idv_manifest="$project_root/idvLoginComponent.json"

app=""
usage() { print -- "Usage: ${0:t} --app ABS/第五人格启动器.app" }
while (( $# > 0 )); do
  case "$1" in
    --app)
      (( $# >= 2 )) || { print -u2 -- "--app 需要 App 路径。"; exit 2; }
      app="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) print -u2 -- "未知参数：$1"; usage >&2; exit 2 ;;
  esac
  shift
done

[[ "$app" == /* && -d "$app/Contents/Resources" ]] || { print -u2 -- "--app 必须指向 App：$app"; exit 66; }

fail() { print -u2 -- "离线载荷复核失败：$*"; exit 1; }

payloads="$app/Contents/Resources/OfflinePayloads"
manifest="$payloads/offlinePayloads.json"
[[ -d "$payloads" ]] || fail "App 内没有 OfflinePayloads 目录：$payloads"
[[ -f "$manifest" ]] || fail "缺少载荷清单：$manifest"
/usr/bin/jq -e '.schemaVersion == 1 and .kind == "identityv-offline-payloads"' "$manifest" >/dev/null \
  || fail "载荷清单格式无效"

# extra_ok 是允许出现的「游戏扩展名」路径白名单（相对 App 根）：
# 三个离线下载核心文件是本次刻意随包分发的网易组件；RuntimePatches 里那枚 GDI 补丁
# 是 RC1 起就随包的 runtime 补丁载荷，不属于游戏本体。
typeset -a extra_ok
extra_ok=(
  "Contents/Resources/OfflinePayloads/netease-download-core/downloadIPC.exe"
  "Contents/Resources/OfflinePayloads/netease-download-core/OrbitSDK.dll"
  "Contents/Resources/OfflinePayloads/netease-download-core/aria2c.exe"
  "Contents/Resources/RuntimePatches/gdi32.dll"
)

/usr/bin/python3 - \
  "$app" "$payloads" "$manifest" \
  "$runtime_manifest" "$core_manifest" "$idv_manifest" \
  "${extra_ok[@]}" <<'PY'
import gzip
import hashlib
import json
import os
import sys

app, payloads, manifest_path = sys.argv[1], sys.argv[2], sys.argv[3]
runtime_manifest_path, core_manifest_path, idv_manifest_path = sys.argv[4:7]
allowed_payload_paths = set(sys.argv[7:])


def fail(message):
    print(f"离线载荷复核失败：{message}", file=sys.stderr)
    raise SystemExit(1)


def digest(path):
    h = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def require_pinned(path, byte_count, sha256, label):
    if not os.path.isfile(path) or os.path.islink(path):
        fail(f"{label} 不是普通文件：{path}")
    actual_size = os.path.getsize(path)
    if actual_size != byte_count:
        fail(f"{label} 字节数不符（期望 {byte_count}，实际 {actual_size}）")
    actual_hash = digest(path)
    if actual_hash != sha256:
        fail(f"{label} SHA-256 不符（期望 {sha256[:16]}…，实际 {actual_hash[:16]}…）")
    print(f"  通过 {label}  {actual_size} bytes  {actual_hash[:16]}…")


payload_manifest = json.load(open(manifest_path, encoding="utf-8"))
runtime_manifest = json.load(open(runtime_manifest_path, encoding="utf-8"))
core_manifest = json.load(open(core_manifest_path, encoding="utf-8"))
idv_manifest = json.load(open(idv_manifest_path, encoding="utf-8"))

# 1. 包内清单自己要和发行清单正本一致，否则「包里带了 A、清单说 B」这种偏差会漏过去。
for key, expected, actual in (
    ("runtime.byteCount", runtime_manifest["source"]["byteCount"], payload_manifest["runtime"]["byteCount"]),
    ("runtime.sha256", runtime_manifest["source"]["sha256"], payload_manifest["runtime"]["sha256"]),
    ("runtime.version", runtime_manifest["version"], payload_manifest["runtime"]["version"]),
    ("idvLogin.byteCount", idv_manifest["byteSize"], payload_manifest["idvLogin"]["byteCount"]),
    ("idvLogin.sha256", idv_manifest["sha256"], payload_manifest["idvLogin"]["sha256"]),
    ("idvLogin.version", idv_manifest["version"], payload_manifest["idvLogin"]["version"]),
    ("downloadCore.commit", core_manifest["acquisition"]["commit"], payload_manifest["downloadCore"]["commit"]),
):
    if expected != actual:
        fail(f"包内载荷清单与发行清单正本不一致：{key}")

expected_core = {entry["filename"]: (entry["byteCount"], entry["sha256"]) for entry in core_manifest["files"]}
listed_core = {entry["filename"]: (entry["byteCount"], entry["sha256"]) for entry in payload_manifest["downloadCore"]["files"]}
if expected_core != listed_core:
    fail("包内下载核心清单与 downloaderCoreComponent.json 不一致")

# 2. 三个组件逐字节复核。
require_pinned(
    os.path.join(payloads, payload_manifest["runtime"]["file"]),
    runtime_manifest["source"]["byteCount"],
    runtime_manifest["source"]["sha256"],
    "基础 runtime 镜像",
)

for filename, (byte_count, sha256) in sorted(expected_core.items()):
    require_pinned(
        os.path.join(payloads, payload_manifest["downloadCore"]["directory"], filename),
        byte_count,
        sha256,
        f"网易下载核心 {filename}",
    )

gzip_path = os.path.join(payloads, payload_manifest["idvLogin"]["file"])
require_pinned(
    gzip_path,
    payload_manifest["idvLogin"]["payloadByteCount"],
    payload_manifest["idvLogin"]["payloadSha256"],
    "idv-login 压缩载荷",
)
h = hashlib.sha256()
decompressed_size = 0
with gzip.open(gzip_path, "rb") as source:
    for block in iter(lambda: source.read(1024 * 1024), b""):
        decompressed_size += len(block)
        h.update(block)
if decompressed_size != idv_manifest["byteSize"]:
    fail(f"idv-login 解压后字节数不符（期望 {idv_manifest['byteSize']}，实际 {decompressed_size}）")
if h.hexdigest() != idv_manifest["sha256"]:
    fail("idv-login 解压后 SHA-256 不符")
print(f"  通过 idv-login 解压还原  {decompressed_size} bytes  {h.hexdigest()[:16]}…")

# 3. 白名单之外不得出现游戏 payload。离线整包的边界就是「除了游戏本体，其他都带」。
forbidden = []
for directory, _, names in os.walk(app):
    for name in names:
        path = os.path.join(directory, name)
        relative = os.path.relpath(path, app)
        if name.lower().endswith((".exe", ".dll", ".pak", ".ucas", ".utoc")):
            if relative not in allowed_payload_paths:
                forbidden.append(relative)
if forbidden:
    for relative in sorted(forbidden):
        print(f"  越界 payload：{relative}", file=sys.stderr)
    fail(f"App 内出现 {len(forbidden)} 个白名单之外的游戏 payload")

print("离线载荷复核通过：三个组件齐全，且 App 内没有游戏本体。")
PY

/usr/bin/du -sh "$payloads" | /usr/bin/sed 's/^/  OfflinePayloads 合计 /'
