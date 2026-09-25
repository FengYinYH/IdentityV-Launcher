#!/bin/zsh
# prepareOfflinePayloads.command — 把「离线整包」需要的三个上游组件落到本机载荷目录并逐个校验。
#
# 为什么存在：公开发行版让启动器在首装时从 GitHub 现取基础 runtime、idv-login 和网易下载核心；
# 目标用户可能只能访问网易，取不到 GitHub。离线整包要把这些字节提前放进安装包，所以先要有
# 一份**逐字节可信**的本地副本。这里只做「取得 + 校验 + 落盘」，不修改 App、不签名、不安装。
#
# 来源与哈希不在这里另写一份：runtime 取 runtimeBootstrap/runtime-manifest.json，
# 网易下载核心取 downloaderCoreComponent.json，idv-login 取 idvLoginComponent.json。
# 那三份清单是发行契约的正本；重复登记会让「包里的字节」和「清单说的字节」有机会悄悄分叉。
#
# 取得顺序：载荷目录已有 → 本机已装组件缓存 → 按清单固定 HTTPS URL 下载。
# 无论走哪条路径，最后都用同一套大小 + SHA-256 校验，失败即整条命令失败。
#
# 用法：
#   ./offlinePackaging/prepareOfflinePayloads.command [--payload-root ABS_DIR] [--check-only]
set -euo pipefail

script_dir="${0:A:h}"
project_root="${script_dir:h}"

runtime_manifest="$project_root/runtimeBootstrap/runtime-manifest.json"
core_manifest="$project_root/downloaderCoreComponent.json"
idv_manifest="$project_root/idvLoginComponent.json"

payload_root="${IDENTITYV_OFFLINE_PAYLOAD_ROOT:-$project_root/local/offlinePayloads}"
check_only=0

usage() {
  print -- "Usage: ${0:t} [--payload-root ABS_DIR] [--check-only]"
  print -- "  --payload-root  DIR   载荷目录（默认 \$PROJECT_ROOT/local/offlinePayloads）"
  print -- "  --check-only          只校验已有载荷，不下载、不复制"
}

while (( $# > 0 )); do
  case "$1" in
    --payload-root)
      (( $# >= 2 )) || { print -u2 -- "--payload-root 需要一个目录参数。"; exit 2; }
      payload_root="$2"; shift ;;
    --check-only) check_only=1 ;;
    -h|--help) usage; exit 0 ;;
    *) print -u2 -- "未知参数：$1"; usage >&2; exit 2 ;;
  esac
  shift
done

[[ "$payload_root" == /* ]] || { print -u2 -- "--payload-root 必须是绝对路径。"; exit 64; }
for tool in /usr/bin/jq /usr/bin/shasum /usr/bin/curl; do
  [[ -x "$tool" ]] || { print -u2 -- "缺少必需工具：$tool"; exit 69; }
done
for manifest in "$runtime_manifest" "$core_manifest" "$idv_manifest"; do
  [[ -f "$manifest" ]] || { print -u2 -- "缺少组件清单：$manifest"; exit 66; }
done

fail() { print -u2 -- "载荷准备失败：$*"; exit 1; }

# 统一的落盘校验：普通文件、非符号链接、字节数与 SHA-256 都必须和清单一致。
verify_pinned() {
  local path="$1" expected_bytes="$2" expected_hash="$3" label="$4"
  [[ -f "$path" && ! -L "$path" ]] || fail "$label 不是普通文件：$path"
  local actual_bytes actual_hash
  actual_bytes="$(/usr/bin/stat -f %z "$path")"
  [[ "$actual_bytes" == "$expected_bytes" ]] || fail "$label 字节数不符（期望 $expected_bytes，实际 $actual_bytes）：$path"
  actual_hash="$(/usr/bin/shasum -a 256 "$path" | /usr/bin/awk '{print $1}')"
  [[ "$actual_hash" == "$expected_hash" ]] || fail "$label SHA-256 不符（期望 $expected_hash，实际 $actual_hash）：$path"
  print -- "  校验通过 $label  $actual_bytes bytes  ${actual_hash[1,16]}…"
}

# 把一个还没进载荷目录的已知好副本复制进来（本机已装组件缓存）。
adopt_local_copy() {
  local source="$1" destination="$2" expected_bytes="$3" expected_hash="$4" label="$5"
  [[ -f "$source" && ! -L "$source" ]] || return 1
  verify_pinned "$source" "$expected_bytes" "$expected_hash" "$label（本机缓存）" || return 1
  /bin/mkdir -p "${destination:h}"
  /bin/cp "$source" "$destination"
  /bin/chmod 600 "$destination"
  return 0
}

download_pinned() {
  local url="$1" destination="$2" expected_bytes="$3" expected_hash="$4" label="$5"
  [[ "$url" == https://* ]] || fail "$label 的来源不是 HTTPS：$url"
  /bin/mkdir -p "${destination:h}"
  print -- "  下载 $label …"
  /usr/bin/curl --fail --location --retry 3 --retry-delay 5 \
    --output "$destination.partial" "$url" || fail "$label 下载失败：$url"
  /bin/mv -f "$destination.partial" "$destination"
  /bin/chmod 600 "$destination"
  verify_pinned "$destination" "$expected_bytes" "$expected_hash" "$label" || fail "$label 下载后校验失败"
}

print -- "离线载荷目录：$payload_root"

# ── 1. 基础 Wine runtime 镜像（DWRG.dmg） ────────────────────────────────────────
runtime_url="$(/usr/bin/jq -r '.source.url' "$runtime_manifest")"
runtime_bytes="$(/usr/bin/jq -r '.source.byteCount' "$runtime_manifest")"
runtime_hash="$(/usr/bin/jq -r '.source.sha256' "$runtime_manifest")"
runtime_file="$payload_root/DWRG.dmg"
print -- "基础 runtime：$runtime_url"
if [[ -f "$runtime_file" ]]; then
  verify_pinned "$runtime_file" "$runtime_bytes" "$runtime_hash" "基础 runtime"
elif (( check_only )); then
  fail "缺少基础 runtime 载荷：$runtime_file"
else
  download_pinned "$runtime_url" "$runtime_file" "$runtime_bytes" "$runtime_hash" "基础 runtime"
fi

# ── 2. idv-login 6.3.0（arm64 Mach-O） ─────────────────────────────────────────
idv_url="$(/usr/bin/jq -r '.downloadURL' "$idv_manifest")"
idv_bytes="$(/usr/bin/jq -r '.byteSize' "$idv_manifest")"
idv_hash="$(/usr/bin/jq -r '.sha256' "$idv_manifest")"
idv_asset="$(/usr/bin/jq -r '.assetName' "$idv_manifest")"
idv_version="$(/usr/bin/jq -r '.version' "$idv_manifest")"
idv_file="$payload_root/$idv_asset"
idv_cache="$HOME/Library/Application Support/IdentityVOnMac/Components/IdvLoginDownload/$idv_version/$idv_asset"
print -- "idv-login：$idv_url"
if [[ -f "$idv_file" ]]; then
  verify_pinned "$idv_file" "$idv_bytes" "$idv_hash" "idv-login $idv_version"
elif (( check_only )); then
  fail "缺少 idv-login 载荷：$idv_file"
elif adopt_local_copy "$idv_cache" "$idv_file" "$idv_bytes" "$idv_hash" "idv-login $idv_version"; then
  :
else
  download_pinned "$idv_url" "$idv_file" "$idv_bytes" "$idv_hash" "idv-login $idv_version"
fi

# ── 3. 网易下载核心（PE 文件） ──────────────────────────────────────────────────
core_base_url="$(/usr/bin/jq -r '.acquisition.sourceBaseURL' "$core_manifest")"
core_commit="$(/usr/bin/jq -r '.acquisition.commit' "$core_manifest")"
core_cache_root="$HOME/Library/Application Support/IdentityVOnMac/Components/netease-download-core/$core_commit"
core_root="$payload_root/netease-download-core"
print -- "网易下载核心：${core_base_url}（commit $core_commit）"
core_count="$(/usr/bin/jq -r '.files | length' "$core_manifest")"
for index in $(/usr/bin/seq 0 $(( core_count - 1 ))); do
  filename="$(/usr/bin/jq -r ".files[$index].filename" "$core_manifest")"
  file_bytes="$(/usr/bin/jq -r ".files[$index].byteCount" "$core_manifest")"
  file_hash="$(/usr/bin/jq -r ".files[$index].sha256" "$core_manifest")"
  destination="$core_root/$filename"
  if [[ -f "$destination" ]]; then
    verify_pinned "$destination" "$file_bytes" "$file_hash" "$filename"
  elif (( check_only )); then
    fail "缺少网易下载核心载荷：$destination"
  elif adopt_local_copy "$core_cache_root/$filename" "$destination" "$file_bytes" "$file_hash" "$filename"; then
    :
  else
    download_pinned "${core_base_url}${filename}" "$destination" "$file_bytes" "$file_hash" "$filename"
  fi
done

print -- "载荷准备完成："
/usr/bin/du -sh "$payload_root"/* 2>/dev/null | /usr/bin/sed 's/^/  /'
