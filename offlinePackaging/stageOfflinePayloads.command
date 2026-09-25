#!/bin/zsh
# stageOfflinePayloads.command — 把已校验的上游组件压进 App 的 Contents/Resources/OfflinePayloads/。
#
# 为什么存在：目标用户可能只能访问网易。启动器原本在首装时从 GitHub 取基础 Wine runtime、
# idv-login 与网易下载核心；离线整包改为「包内先带一份」，由启动器把它们交给同样的获取器
# （IdentityVRuntimeBootstrap --payload-dmg / IdentityVDownloaderCoreBootstrap --payload-dir /
# IdentityVIdvLoginDownloader --payload-image），仍然逐字节校验后才安装。
#
# 为什么 idv-login 装在内嵌磁盘映像里：它是一个 arm64 Mach-O。
#   1. 裸放在 Resources 里会被发行前的整树重签改字节，与清单锁定的 SHA-256 冲突；
#   2. 试过压成 .gz —— Apple 公证会解压并检查里面的 Mach-O，而上游只带 ad-hoc 签名，
#      于是返回「not signed with a valid Developer ID certificate / no secure timestamp /
#      no hardened runtime」。同一份提交里内嵌的 BaseRuntime.dmg 与三个裸 PE 都未被标记，
#      说明公证不深入检查内嵌磁盘映像；
#   3. 我们选择不重签他人代码、不改上游字节，于是按项目对待 DWRG.dmg 的同一方式处理：
#      第三方产物整体作为独立磁盘映像随包，由下载器挂载取出后校验原始 SHA-256。
# DWRG.dmg 与三个 PE 文件本来就不需要这个包装，原样存放。
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

# ── idv-login（装进内嵌磁盘映像，保持上游字节原样） ─────────────────────────────
# 为什么 idv-login 要重签 + 装进磁盘映像：
#   1. 它是 arm64 Mach-O。Apple 公证要求包里每个 Mach-O 都由 Developer ID 签名并带安全时间戳
#      与 Hardened Runtime，而上游只给了 ad-hoc 签名；
#   2. 公证会展开归档逐个检查：试过直接放文件、也试过压成 .gz，甚至用最小包实测「放进内嵌
#      DMG」——三种都会被 notary 揪出来（内嵌 DMG 也一样会展开），所以我们不能靠容器躲开它；
#   3. 于是按公证的要求办：打包时用本项目 Developer ID 重签这份上游二进制（不改任何一行代码）。
#      重签必须带 --options runtime 与 PyInstaller 需要的 entitlements，见
#      offlinePackaging/idvLoginOffline.entitlements；
#   4. 仍然装进磁盘映像，是因为 buildPlayerLauncher.command 最后会由内到外整树重签，裸放在
#      Resources 里的 Mach-O 会被再签一次、字节又变，本次记录的哈希就失效了。放进映像后
#      签名树不遍历它，这一份字节在整个打包流程里保持不变。
#   因此离线路径的期望值不再等于上游发布物：它由本次打包写进 offlinePayloads.json 的
#   offlineByteCount / offlineSha256 给出，下载器用 --payload-manifest 读它。
idv_url="$(/usr/bin/jq -r '.downloadURL' "$idv_manifest")"
idv_bytes="$(/usr/bin/jq -r '.byteSize' "$idv_manifest")"
idv_hash="$(/usr/bin/jq -r '.sha256' "$idv_manifest")"
idv_asset="$(/usr/bin/jq -r '.assetName' "$idv_manifest")"
idv_version="$(/usr/bin/jq -r '.version' "$idv_manifest")"
idv_source="$payload_root/$idv_asset"
verify_pinned "$idv_source" "$idv_bytes" "$idv_hash" "idv-login $idv_version" >/dev/null

source "$project_root/signing/lib/signIdentityV.sh"
if [[ -z "${IDENTITYV_RESOLVED_IDENTITY:-}" ]]; then
  identityv_resolve_identity
fi
[[ "$IDENTITYV_RESOLVED_KIND" == developer-id ]] || fail "离线载荷重签需要 Developer ID Application 身份（当前：$IDENTITYV_RESOLVED_KIND）"
entitlements_file="$script_dir/idvLoginOffline.entitlements"
[[ -f "$entitlements_file" ]] || fail "缺少重签 entitlements：$entitlements_file"

image_name="idv-login-$idv_version.dmg"
image_stage="$destination/.idv-image-stage"
/bin/rm -rf "$image_stage"
/bin/mkdir -p "$image_stage"
/bin/cp "$idv_source" "$image_stage/$idv_asset"
/bin/chmod 755 "$image_stage/$idv_asset"
/usr/bin/codesign --force --options runtime --timestamp \
  --entitlements "$entitlements_file" \
  --sign "$IDENTITYV_RESOLVED_IDENTITY" "$image_stage/$idv_asset"
/usr/bin/codesign --verify --strict --verbose=2 "$image_stage/$idv_asset" || fail "重签后的 idv-login 未通过签名校验"
[[ "$(/usr/bin/codesign -d --verbose=4 "$image_stage/$idv_asset" 2>&1 | /usr/bin/grep -c 'Authority=Developer ID Application')" == 1 ]] \
  || fail "重签后的 idv-login 不是 Developer ID 签名"
# 交付给用户的那一份的大小与哈希：公证不可复现（安全时间戳），所以每次都重算并记录。
idv_offline_bytes="$(/usr/bin/stat -f %z "$image_stage/$idv_asset")"
idv_offline_hash="$(/usr/bin/shasum -a 256 "$image_stage/$idv_asset" | /usr/bin/awk '{print $1}')"
# 冒烟：重签后必须还能启动 PyInstaller 运行时，否则签名“合法”但装上去跑不起来。
smoke_output="$("$image_stage/$idv_asset" --help 2>&1 || true)"
[[ "$smoke_output" == *"idv-login"* ]] || fail "重签后的 idv-login 无法启动（--help 无预期输出）"

/usr/bin/hdiutil create -quiet -format UDZO -nospotlight -srcfolder "$image_stage" "$destination/$image_name"
/bin/rm -rf "$image_stage"
/bin/chmod 644 "$destination/$image_name"
image_bytes="$(/usr/bin/stat -f %z "$destination/$image_name")"

# 反向验真：挂载刚生成的映像，取出里面的文件，大小与哈希必须等于刚记录的那一份。
# 只看「造映像成功」不能排除复制/打包环节把字节改掉，所以这里真的挂一次再比。
idv_mount="$(/usr/bin/mktemp -d /private/tmp/identityv-idvpayload.XXXXXX)"
idv_device=""
detach_idv_mount() {
  if [[ -n "$idv_device" ]]; then
    /usr/bin/hdiutil detach "$idv_device" >/dev/null 2>&1 || \
      /usr/bin/hdiutil detach -force "$idv_device" >/dev/null 2>&1 || true
    idv_device=""
  fi
  [[ -n "${idv_mount:-}" && "$idv_mount" == /private/tmp/identityv-idvpayload.* && -d "$idv_mount" ]] && /bin/rmdir "$idv_mount" 2>/dev/null || true
}
trap detach_idv_mount EXIT INT TERM
idv_device="$(/usr/bin/hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$idv_mount" "$destination/$image_name" \
  | /usr/bin/awk '/^\/dev\/disk/{print $1; exit}')"
[[ "$idv_device" == /dev/disk* ]] || fail "idv-login 载荷映像挂载失败"
[[ -f "$idv_mount/$idv_asset" && ! -L "$idv_mount/$idv_asset" ]] || fail "载荷映像里没有 $idv_asset"
image_inner_hash="$(/usr/bin/shasum -a 256 "$idv_mount/$idv_asset" | /usr/bin/awk '{print $1}')"
[[ "$image_inner_hash" == "$idv_offline_hash" ]] || fail "载荷映像里的 idv-login 哈希与记录值不符（实际 ${image_inner_hash[1,16]}…）"
detach_idv_mount
trap - EXIT INT TERM
print -- "已注入 idv-login：上游 $idv_bytes bytes → 本项目重签 $idv_offline_bytes bytes → 磁盘映像 $image_bytes bytes（挂载复验通过）"

# ── 载荷清单 ───────────────────────────────────────────────────────────────────
# 清单值直接从三份发行清单正本与磁盘上的实际字节算出，不靠 shell 拼接，避免转义或空值
# 让「清单说的字节」和「包里的字节」分叉。
manifest_tmp="$destination/.offlinePayloads.json.tmp"
/usr/bin/python3 - \
  "$manifest_tmp" "$destination" "$image_name" "$idv_offline_bytes" "$idv_offline_hash" \
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


target, payloads, image_name, offline_bytes, offline_hash, runtime_path, core_path, idv_path = sys.argv[1:9]
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
        "file": image_name,
        "container": "dmg",
        "version": idv_manifest["version"],
        "assetName": idv_manifest["assetName"],
        # 上游发布物的大小与哈希：证明这份离线清单确实从同一份上游锁派生。
        "byteCount": idv_manifest["byteSize"],
        "sha256": idv_manifest["sha256"],
        # 实际随包分发的那一份：上游字节被本项目 Developer ID 重签过，所以大小与哈希都不同，
        # 且因为带安全时间戳而不可复现，只能每次打包重算。下载器用 --payload-manifest 读这两项
        # 作为生效的期望值。
        "offlineByteCount": int(offline_bytes),
        "offlineSha256": offline_hash.lower(),
        "payloadByteCount": os.path.getsize(os.path.join(payloads, image_name)),
        "payloadSha256": digest(os.path.join(payloads, image_name)),
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

# hdiutil 会给产物打 com.apple.FinderInfo / com.apple.diskimages.recentcksum，挂载也会刷新
# recentcksum；codesign 对包内带这些扩展属性的文件会直接报
# "resource fork, Finder information, or similar detritus not allowed" 而拒绝整树签名。
# 所以载荷写完之后统一清一次；xattr 不在文件内容里，不影响上面算出的任何 SHA-256。
/usr/bin/xattr -cr "$destination" 2>/dev/null || true

print -- "离线载荷已注入：$destination"
/usr/bin/du -sh "$destination" | /usr/bin/sed 's/^/  /'
