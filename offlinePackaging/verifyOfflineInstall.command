#!/bin/zsh
# verifyOfflineInstall.command — 用**包内**的三个获取器，在隔离 HOME 里证明「离线路径真的离线」。
#
# 为什么需要这一步：只验证 App 里带着载荷字节，不能证明启动器会走本地路径，也不能证明它
# 真的不再联网。这里做的是行为验收：
#   试验组  带 --payload-* 参数、并把 HTTP(S) 代理指到一个必然连不上的端口 + 隔离 HOME
#           → 三个组件都必须装成功且通过校验；
#   对照组  同一批 helper 去掉 --payload-* 参数，环境不变
#           → 必须失败。对照组失败才能说明试验组的成功来自本地载荷，而不是「恰好还能联网」。
#
# 它不安装到真实用户目录、不启动游戏、不改 /Applications；全部写入临时目录并在结束时删除。
#
# 用法：./offlinePackaging/verifyOfflineInstall.command --app ABS/第五人格启动器.app
set -euo pipefail

script_dir="${0:A:h}"
project_root="${script_dir:h}"
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

resources="$app/Contents/Resources"
payloads="$resources/OfflinePayloads"
runtime_bootstrap="$resources/IdentityVRuntimeBootstrap"
core_bootstrap="$resources/IdentityVDownloaderCoreBootstrap"
idv_downloader="$resources/IdentityVIdvLoginDownloader"
runtime_manifest="$resources/runtime-manifest.json"
core_manifest="$resources/downloaderCoreComponent.json"
idv_manifest="$resources/idvLoginComponent.json"
patch_root="$resources/RuntimePatches"

for asset in "$runtime_bootstrap" "$core_bootstrap" "$idv_downloader" "$runtime_manifest" "$core_manifest" "$idv_manifest"; do
  [[ -e "$asset" ]] || { print -u2 -- "App 内缺少获取器或清单：$asset"; exit 66; }
  [[ -x "$asset" || "$asset" == *.json ]] || { print -u2 -- "获取器不可执行：$asset"; exit 66; }
done
[[ -d "$payloads" ]] || { print -u2 -- "App 内没有 OfflinePayloads，无法做离线安装验收：$payloads"; exit 66; }

work="$(/usr/bin/mktemp -d /private/tmp/identityv-offline-verify.XXXXXX)"
fake_home="$work/home"
mkdir -p "$fake_home"
cleanup() { /bin/rm -rf -- "$work"; }
trap cleanup EXIT INT TERM

# 必然连不上的代理：端口 9（discard）在本机没有监听，连接会立刻被拒绝。
# Go 的默认 Transport 读 HTTP_PROXY/HTTPS_PROXY/ALL_PROXY，因此这是对「不带载荷就会联网」的一般性阻断。
block_env=(HTTP_PROXY=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 ALL_PROXY=http://127.0.0.1:9 NO_PROXY= no_proxy=)

fail() { print -u2 -- "离线安装验收失败：$*"; exit 1; }

print -- "隔离 HOME：$fake_home"
print -- "阻断代理：http://127.0.0.1:9（连接必然被拒绝）"

# ── 试验组 1：基础 runtime ─────────────────────────────────────────────────────
print -- "① 试验组 · 基础 runtime（--payload-dmg）"
runtime_root="$fake_home/Library/Application Support/IdentityVOnMac/Components/wine-runtime"
/usr/bin/env -i HOME="$fake_home" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  "${block_env[@]}" \
  "$runtime_bootstrap" install \
    --manifest "$runtime_manifest" \
    --destination-root "$runtime_root" \
    --patch-root "$patch_root" \
    --payload-dmg "$payloads/BaseRuntime.dmg" > "$work/runtime.log" 2>&1 \
  || { /usr/bin/tail -20 "$work/runtime.log" >&2; fail "带载荷的 runtime 安装失败"; }
[[ -L "$runtime_root/current" ]] || fail "runtime 安装后没有 current 链接"
runtime_version="$(/usr/bin/jq -r '.version' "$runtime_manifest")"
"$runtime_bootstrap" verify-tree --manifest "$runtime_manifest" --tree "$runtime_root/$runtime_version" >/dev/null \
  || fail "装好的 runtime 未通过 verify-tree"
print -- "  通过：$runtime_version"

# ── 试验组 2：网易下载核心 ────────────────────────────────────────────────────
print -- "② 试验组 · 网易下载核心（--payload-dir）"
core_root="$fake_home/Library/Application Support/IdentityVOnMac/Components/netease-download-core"
/usr/bin/env -i HOME="$fake_home" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  "${block_env[@]}" \
  "$core_bootstrap" install \
    --manifest "$core_manifest" \
    --destination-root "$core_root" \
    --payload-dir "$payloads/netease-download-core" > "$work/core.log" 2>&1 \
  || { /usr/bin/tail -20 "$work/core.log" >&2; fail "带载荷的下载核心安装失败"; }
[[ -L "$core_root/current" ]] || fail "下载核心安装后没有 current 链接"
core_commit="$(/usr/bin/jq -r '.acquisition.commit' "$core_manifest")"
for filename in downloadIPC.exe OrbitSDK.dll aria2c.exe; do
  expected="$(/usr/bin/jq -r --arg f "$filename" '.files[] | select(.filename == $f) | .sha256' "$core_manifest")"
  actual="$(/usr/bin/shasum -a 256 "$core_root/$core_commit/$filename" | /usr/bin/awk '{print $1}')"
  [[ "$actual" == "$expected" ]] || fail "下载核心 $filename 安装后哈希不符"
done
print -- "  通过：commit $core_commit"

# ── 试验组 3：idv-login ───────────────────────────────────────────────────────
# 期望值是「本项目重签后的那一份」，来自包内离线清单，不是上游发布物的哈希。
print -- "③ 试验组 · idv-login（--payload-image + --payload-manifest）"
idv_version="$(/usr/bin/jq -r '.version' "$idv_manifest")"
idv_asset="$(/usr/bin/jq -r '.assetName' "$idv_manifest")"
offline_manifest_path="$payloads/offlinePayloads.json"
idv_hash="$(/usr/bin/jq -r '.idvLogin.offlineSha256' "$offline_manifest_path")"
idv_cache="$fake_home/Library/Application Support/IdentityVOnMac/Components/IdvLoginDownload/$idv_version"
published="$(/usr/bin/env -i HOME="$fake_home" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  "${block_env[@]}" \
  "$idv_downloader" "$idv_manifest" "$idv_cache" \
    --payload-image "$payloads/idv-login-$idv_version.dmg" \
    --payload-manifest "$offline_manifest_path" 2>"$work/idv.log")" \
  || { /usr/bin/tail -20 "$work/idv.log" >&2; fail "带载荷的 idv-login 发布失败"; }
[[ "$published" == "$idv_cache/$idv_asset" ]] || fail "idv-login 返回的路径不符合预期：$published"
[[ "$(/usr/bin/shasum -a 256 "$published" | /usr/bin/awk '{print $1}')" == "$idv_hash" ]] \
  || fail "idv-login 发布后哈希与包内清单不符"
print -- "  通过：$idv_asset"

# ── 对照组：同样的 helper、同样的阻断代理，只是不给载荷 ────────────────────────
# 这三步必须失败。任何一步「成功」都说明阻断没有生效，或者获取器在没载荷时仍能凑出结果，
# 那样上面三组通过就失去意义。
print -- "④ 对照组 · 去掉载荷参数，应当失败"
group_failures=0
check_group_fails() {
  local label="$1"; shift
  if "$@" > "$work/control.log" 2>&1; then
    print -u2 -- "  对照组「$label」意外成功；阻断未生效或存在未预期的本地兜底。"
    (( group_failures += 1 ))
  else
    print -- "  符合预期失败：$label"
  fi
}
check_group_fails "runtime 无载荷" /usr/bin/env -i HOME="$fake_home" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  "${block_env[@]}" "$runtime_bootstrap" install --manifest "$runtime_manifest" \
  --destination-root "$work/control-wine-runtime" --patch-root "$patch_root"
check_group_fails "下载核心无载荷" /usr/bin/env -i HOME="$fake_home" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  "${block_env[@]}" "$core_bootstrap" install --manifest "$core_manifest" \
  --destination-root "$work/control-core"
check_group_fails "idv-login 无载荷" /usr/bin/env -i HOME="$fake_home" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
  "${block_env[@]}" "$idv_downloader" "$idv_manifest" "$work/control-idv"
(( group_failures == 0 )) || fail "对照组有 $group_failures 项意外成功"

print -- "离线安装验收通过：三个组件在阻断代理下都由包内载荷装成，去掉载荷则全部失败。"
