#!/bin/zsh
# stageOfflinePayloads.command — 把已校验的上游组件压进 App 的 Contents/Resources/OfflinePayloads/。
#
# 为什么存在：目标用户可能只能访问网易。启动器原本在首装时从 GitHub 取基础 Wine runtime、
# idv-login 与网易下载核心；离线整包改为「包内先带一份」，由启动器把它们交给同样的获取器
# （IdentityVRuntimeBootstrap --payload-dmg / IdentityVDownloaderCoreBootstrap --payload-dir /
# IdentityVIdvLoginDownloader --payload），仍然逐字节校验后才安装。
#
# 为什么 idv-login 要 gzip：它是一个 arm64 Mach-O。App 在发行前要由内到外整树重签，任何留在
# Resources 里的裸 Mach-O 都会被签名改字节，而组件清单锁的是原始 SHA-256，两者必然冲突。
# 压成 .gz 后它不再被 codesign 当作代码对象，解压后由 Go 侧校验原始大小与哈希。
# DWRG.dmg 与三个 PE 文件本来就不是 Mach-O，可以原样存放。
#
# 这个步骤不签名、不公证、不安装；它只在 buildPlayerLauncher.command 显式设置了
# IDENTITYV_OFFLINE_PAYLOAD_ROOT 时被调用，公开发行路径不受影响。
#
# 用法：./offlinePackaging/stageOfflinePayloads.command --payload-root ABS_DIR --app ABS/第五人格启动器.app
set -euo pipefail

script_dir="${0:A:h}"
project_root="${script_dir:h}"

runtime_manifest="$project_root/runtimeBootstrap/runtime-manifest.json"
core_manifest="$project_root/downloaderCoreComponent.json"
idv_manifest="$project_root/idvLoginComponent.json"

payload_root=""
app=""

usage() {
  print -- "Usage: ${0:t} --payload-root ABS_DIR --app ABS/第五人格启动器.app"
}

while (( $# > 0 )); do
  case "$1" in
    --payload-root)
      (( $# >= 2 )) || { print -u2 -- "--payload-root 需要一个目录参数。"; exit 2; }
      payload_root="$2"; shift ;;
    --app)
      (( $# >= 2 )) || { print -u2 -- "--app 需要 App 路径。"; exit 2; }
      app="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) print -u2 -- "未知参数：$1"; usage >&2; exit 2 ;;
  esac
  shift
done

[[ "$payload_root" == /* ]] || { print -u2 -- "--payload-root 必须是绝对路径。"; exit 64; }
[[ "$app" == /* && -d "$app/Contents/Resources" ]] || { print -u2 -- "--app 必须指向已构建的 App：$app"; exit 66; }
[[ -d "$payload_root" ]] || { print -u2 -- "载荷目录不存在：$payload_root（先运行 prepareOfflinePayloads.command）"; exit 66; }

fail() { print -u2 -- "离线载荷注入失败：$*"; exit 1; }

verify_pinned() {
  local path="$1" expected_bytes="$2" expected_hash="$3" label="$4"
  [[ -f "$path" && ! -L "$path" ]] || fail "$label 不是普通文件：$path"
  local actual_bytes actual_hash
  actual_bytes="$(/usr/bin/stat -f %z "$path")"
  [[ "$actual_bytes" == "$expected_bytes" ]] || fail "$label 字节数不符（期望 $expected_bytes，实际 $actual_bytes）"
  actual_hash="$(/usr/bin/shasum -a 256 "$path" | /usr/bin/awk '{print $1}')"
  [[ "$actual_hash" == "$expected_hash" ]] || fail "$label SHA-256 不符"
  print -- "$actual_hash"
}

resources="$app/Contents/Resources"
destination="$resources/OfflinePayloads"
[[ ! -e "$destination" || -d "$destination" ]] || fail "目标路径已存在且不是目录：$destination"
/bin/rm -rf "$destination"
/bin/mkdir -p "$destination/netease-download-core"

# ── 基础 runtime 镜像 ──────────────────────────────────────────────────────────
runtime_url="$(/usr/bin/jq -r '.source.url' "$runtime_manifest")"
runtime_bytes="$(/usr/bin/jq -r '.source.byteCount' "$runtime_manifest")"
runtime_hash="$(/usr/bin/jq -r '.source.sha256' "$runtime_manifest")"
verify_pinned "$payload_root/DWRG.dmg" "$runtime_bytes" "$runtime_hash" "基础 runtime" >/dev/null
/bin/cp "$payload_root/DWRG.dmg" "$destination/BaseRuntime.dmg"
/bin/chmod 644 "$destination/BaseRuntime.dmg"
print -- "已注入基础 runtime：$runtime_bytes bytes"

# ── 网易下载核心 ───────────────────────────────────────────────────────────────
core_base_url="$(/usr/bin/jq -r '.acquisition.sourceBaseURL' "$core_manifest")"
core_commit="$(/usr/bin/jq -r '.acquisition.commit' "$core_manifest")"
core_count="$(/usr/bin/jq -r '.files | length' "$core_manifest")"
for index in $(/usr/bin/seq 0 $(( core_count - 1 ))); do
  filename="$(/usr/bin/jq -r ".files[$index].filename" "$core_manifest")"
  file_bytes="$(/usr/bin/jq -r ".files[$index].byteCount" "$core_manifest")"
  file_hash="$(/usr/bin/jq -r ".files[$index].sha256" "$core_manifest")"
  verify_pinned "$payload_root/netease-download-core/$filename" "$file_bytes" "$file_hash" "$filename" >/dev/null
  /bin/cp "$payload_root/netease-download-core/$filename" "$destination/netease-download-core/$filename"
  /bin/chmod 644 "$destination/netease-download-core/$filename"
  print -- "已注入网易下载核心：$filename（$file_bytes bytes）"
done

# ── idv-login（gzip 存放，解压后校验原始大小与哈希） ─────────────────────────────
idv_url="$(/usr/bin/jq -r '.downloadURL' "$idv_manifest")"
idv_bytes="$(/usr/bin/jq -r '.byteSize' "$idv_manifest")"
idv_hash="$(/usr/bin/jq -r '.sha256' "$idv_manifest")"
idv_asset="$(/usr/bin/jq -r '.assetName' "$idv_manifest")"
idv_version="$(/usr/bin/jq -r '.version' "$idv_manifest")"
idv_source="$payload_root/$idv_asset"
verify_pinned "$idv_source" "$idv_bytes" "$idv_hash" "idv-login $idv_version" >/dev/null
# -n 省略原始文件名与时间戳，让同样的输入压出同样的字节；否则每次打包的包内哈希都会变。
gzip_name="idv-login-$idv_version.gz"
/usr/bin/gzip -9 -n -c "$idv_source" > "$destination/$gzip_name"
/bin/chmod 644 "$destination/$gzip_name"
# 反向验真：解压回来必须还是锁定的那份字节，避免「压坏了但没人发现」。
gzip_bytes="$(/usr/bin/stat -f %z "$destination/$gzip_name")"
gzip_hash="$(/usr/bin/shasum -a 256 "$destination/$gzip_name" | /usr/bin/awk '{print $1}')"
decompressed_hash="$(/usr/bin/gzip -dc "$destination/$gzip_name" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
[[ "$decompressed_hash" == "$idv_hash" ]] || fail "idv-login 压缩后解压哈希不符（实际 ${decompressed_hash[1,16]}…）"
print -- "已注入 idv-login：$idv_bytes bytes → gzip $gzip_bytes bytes"

# ── 载荷清单 ───────────────────────────────────────────────────────────────────
# 清单值直接从三份发行清单正本与磁盘上的实际字节算出，不靠 shell 拼接，避免转义或空值
# 让「清单说的字节」和「包里的字节」分叉。
manifest_tmp="$destination/.offlinePayloads.json.tmp"
/usr/bin/python3 - \
  "$manifest_tmp" "$destination" "$gzip_name" \
  "$runtime_manifest" "$core_manifest" "$idv_manifest" <<'PY'
import hashlib
import json
import os
import sys


def digest(path):
    h = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


target, payloads, gzip_name, runtime_path, core_path, idv_path = sys.argv[1:7]
runtime_manifest = json.load(open(runtime_path, encoding="utf-8"))
core_manifest = json.load(open(core_path, encoding="utf-8"))
idv_manifest = json.load(open(idv_path, encoding="utf-8"))

document = {
    "schemaVersion": 1,
    "kind": "identityv-offline-payloads",
    "note": "私有离线整包专用：启动器优先使用这些包内字节；公开发行包不含本目录。",
    "runtime": {
        "file": "BaseRuntime.dmg",
        "version": runtime_manifest["version"],
        "byteCount": runtime_manifest["source"]["byteCount"],
        "sha256": runtime_manifest["source"]["sha256"],
        "upstreamURL": runtime_manifest["source"]["url"],
    },
    "downloadCore": {
        "directory": "netease-download-core",
        "commit": core_manifest["acquisition"]["commit"],
        "sourceBaseURL": core_manifest["acquisition"]["sourceBaseURL"],
        "files": [
            {
                "filename": entry["filename"],
                "byteCount": entry["byteCount"],
                "sha256": entry["sha256"],
            }
            for entry in core_manifest["files"]
        ],
    },
    "idvLogin": {
        "file": gzip_name,
        "compression": "gzip",
        "version": idv_manifest["version"],
        "assetName": idv_manifest["assetName"],
        "byteCount": idv_manifest["byteSize"],
        "sha256": idv_manifest["sha256"],
        "payloadByteCount": os.path.getsize(os.path.join(payloads, gzip_name)),
        "payloadSha256": digest(os.path.join(payloads, gzip_name)),
        "upstreamURL": idv_manifest["downloadURL"],
    },
}
with open(target, "w", encoding="utf-8") as handle:
    json.dump(document, handle, ensure_ascii=False, indent=2, sort_keys=True)
    handle.write("\n")
PY
/bin/mv -f "$manifest_tmp" "$destination/offlinePayloads.json"
/bin/chmod 644 "$destination/offlinePayloads.json"
/usr/bin/jq -e '.schemaVersion == 1 and .kind == "identityv-offline-payloads"' "$destination/offlinePayloads.json" >/dev/null \
  || fail "载荷清单格式无效"

# 随包组件是谁的、能/不能怎么分发，写在这份说明里，跟着载荷一起走。
provenance_source="$script_dir/payloadProvenance.md"
[[ -f "$provenance_source" ]] || fail "缺少来源与许可说明：$provenance_source"
/bin/cp "$provenance_source" "$destination/来源与许可说明.md"
/bin/chmod 644 "$destination/来源与许可说明.md"

print -- "离线载荷已注入：$destination"
/usr/bin/du -sh "$destination" | /usr/bin/sed 's/^/  /'
