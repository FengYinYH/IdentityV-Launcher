#!/bin/zsh
# buildOfflinePackage.command — 生成「离线整包」DMG：把基础 Wine runtime、idv-login 和
# 网易下载核心压进启动器 App，面向只能访问网易的目标用户，让首装不依赖 GitHub。
#
# 为什么单独一条打包路径，而不是给 buildAlpha1Preview.command 加开关：公开发行物的
# 载荷审计**刻意**拒绝 DWRG.dmg / idv-login-v*-mac / downloadIPC / aria2 / Orbit，
# 因为上游没有把基础 runtime 与本项目再分发授权交给我们（见 notices/README.md 与
# runtimeBootstrap/README.md）。离线整包要反过来把这些字节带在包里，两者是相互矛盾的
# 发行策略；把开关塞进公开路径，等于让「公开包」有机会带着被禁止的载荷溜出去。
# 因此这里另开一条路径，公开路径的审计保持原样不动。再分发边界见
# offlinePackaging/payloadProvenance.md。
#
# 这条路径与公开路径一样会签名、公证、staple，并在只读挂载后复验布局、签名与三个载荷的
# 字节；区别只在「允许带哪些组件」和「多一份使用说明」。
#
# 用法：
#   ./offlinePackaging/buildOfflinePackage.command [--rebuild] [--output DIR] [--payload-root DIR]
#   --no-rebuild   复用一个已经注入过离线载荷的既有 App（默认会重新构建）
set -euo pipefail

script_dir="${0:A:h}"
project_root="${script_dir:h}"

build_root="${IDENTITYV_BUILD_ROOT:-$project_root/playerLauncherApp/build}"
[[ "$build_root" == /* ]] || { print -u2 -- "IDENTITYV_BUILD_ROOT 必须是绝对路径。"; exit 64; }
source_app="$build_root/第五人格启动器.app"
payload_root="${IDENTITYV_OFFLINE_PAYLOAD_ROOT:-$project_root/local/offlinePayloads}"
output_root="$script_dir/build"
dmgbuild="$project_root/releasePackaging/.venv/bin/dmgbuild"
dmg_settings="$script_dir/offlineDmgSettings.py"
dmg_background_source="$project_root/releasePackaging/dmgBackground.svg"
dmg_background_generator="$project_root/releasePackaging/makeDmgBackground.swift"
runtime_patch_audit="$project_root/runtimeBootstrap/verifyRuntimePatchPayloads.command"
guide_source="$script_dir/使用说明.txt"
prepare_payloads="$script_dir/prepareOfflinePayloads.command"
stage_payloads="$script_dir/stageOfflinePayloads.command"
verify_payloads="$script_dir/verifyOfflinePayloads.command"
rebuild=1

usage() {
  print -- "Usage: ${0:t} [--no-rebuild] [--output DIRECTORY] [--payload-root DIRECTORY]"
  print -- "  --no-rebuild          直接使用已注入离线载荷的既有 App，不重新构建"
  print -- "  --output DIRECTORY    产物目录（默认 offlinePackaging/build）"
  print -- "  --payload-root DIR    上游组件载荷目录（默认 \$PROJECT_ROOT/local/offlinePayloads）"
}

while (( $# > 0 )); do
  case "$1" in
    --no-rebuild) rebuild=0 ;;
    --output)
      (( $# >= 2 )) || { print -u2 -- "--output 需要一个目录"; exit 2; }
      output_root="$2"; shift ;;
    --payload-root)
      (( $# >= 2 )) || { print -u2 -- "--payload-root 需要一个目录"; exit 2; }
      payload_root="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) print -u2 -- "未知参数：$1"; usage >&2; exit 2 ;;
  esac
  shift
done

[[ "$output_root" == /* ]] || { print -u2 -- "--output 必须是绝对路径。"; exit 64; }
[[ "$payload_root" == /* ]] || { print -u2 -- "--payload-root 必须是绝对路径。"; exit 64; }

# ── 签名身份与公证凭据 ─────────────────────────────────────────────────────────
# 离线整包同样要交给不懂 Gatekeeper 的人双击打开，所以这里不接受 ad-hoc：
# 没有 Developer ID 或没有公证凭据就直接失败，而不是产出一个「右键→打开」才能用的包。
source "$project_root/signing/lib/signIdentityV.sh"
identityv_resolve_identity
notary_profile="${IDENTITYV_NOTARY_PROFILE:-}"
if [[ "$IDENTITYV_RESOLVED_KIND" != developer-id ]]; then
  print -u2 -- "离线整包必须用 Developer ID 签名（当前身份类别：$IDENTITYV_RESOLVED_KIND）。"
  print -u2 -- "设置 IDENTITYV_SIGNING_MODE=developer-id 并确认登录钥匙串里有 Developer ID Application 证书。"
  exit 64
fi
if [[ -z "$notary_profile" ]]; then
  print -u2 -- "离线整包必须公证，但没有设置 IDENTITYV_NOTARY_PROFILE。"
  print -u2 -- "先一次性存入凭据：$project_root/signing/setupNotaryCredentials.command"
  exit 64
fi

for asset in "$dmg_settings" "$guide_source" "$dmg_background_source" "$dmg_background_generator" "$prepare_payloads" "$stage_payloads" "$verify_payloads"; do
  [[ -f "$asset" ]] || { print -u2 -- "缺少打包资产：$asset"; exit 66; }
done
[[ -x "$dmgbuild" ]] || { print -u2 -- "缺少隔离的 DMG 打包环境，请先运行 releasePackaging/preparePackagingEnvironment.command。"; exit 66; }

# ── 载荷准备与构建 ─────────────────────────────────────────────────────────────
print -- "① 准备并校验离线载荷：$payload_root"
"$prepare_payloads" --payload-root "$payload_root"

if (( rebuild )); then
  print -- "② 从源码重建启动器（注入 OfflinePayloads）"
  # IDENTITYV_OFFLINE_PAYLOAD_ROOT 是 buildPlayerLauncher.command 唯一的入口开关：
  # 不设置时公开构建完全不带这些字节。
  IDENTITYV_OFFLINE_PAYLOAD_ROOT="$payload_root" "$project_root/buildPlayerLauncher.command"
else
  print -- "② 复用既有 App（--no-rebuild）"
fi

[[ -d "$source_app" ]] || { print -u2 -- "缺少已构建的 App：$source_app"; exit 1; }
release_version="$(/usr/libexec/PlistBuddy -c 'Print IdentityVReleaseVersion' "$source_app/Contents/Info.plist")"
[[ "$release_version" == [0-9]* && "$release_version" != *[^a-zA-Z0-9.-]* ]] || { print -u2 -- "发行版本格式无效。"; exit 1; }
build_number="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$source_app/Contents/Info.plist")"

print -- "③ 核对 App 身份与包内载荷"
# 这一步要求源码树在构建前是干净的、且发行号没有对应 Git tag；它挡住「编译的是另一套运行时」
# 和「同号重封」。源码有未提交修改时会在这里明确失败，先提交再打包。
/usr/bin/python3 "$project_root/releasePackaging/releaseIdentity.py" verify \
  --repo "$project_root" --app "$source_app"
"$verify_payloads" --app "$source_app"

release_name="第五人格启动器-$release_version-离线整包"
output_root="${output_root:A}"
dmg_path="$output_root/$release_name.dmg"
checksums="$output_root/$release_name-SHA256SUMS.txt"
guide_copy="$output_root/$release_name-使用说明.md"
for published in "$dmg_path" "$checksums" "$guide_copy"; do
  if [[ -e "$published" || -L "$published" ]]; then
    print -u2 -- "产物已存在，拒绝覆盖：$published"
    print -u2 -- "请为本轮候选指定新的 --output 目录，让上一份候选保持可恢复。"
    exit 73
  fi
done
/bin/mkdir -p "$output_root"

stage_root="$(/usr/bin/mktemp -d "$output_root/.stage-offline.XXXXXX")"
[[ "$stage_root" == "$output_root"/.stage-offline.* ]] || { print -u2 -- "暂存路径不安全"; exit 1; }
app_stage="$stage_root/第五人格启动器.app"
temporary_dmg="$stage_root/$release_name.dmg"
background_pdf="$stage_root/dmg-background.pdf"
background_generator="$stage_root/make-dmg-background"
guide_rtf="$stage_root/使用说明.rtf"
attach_plist="$stage_root/attach.plist"
mount_root="$(/usr/bin/mktemp -d /private/tmp/identityv-offline-mount.XXXXXX)"
mounted_device=""

cleanup() {
  if [[ -n "$mounted_device" ]]; then
    /usr/bin/hdiutil detach "$mounted_device" >/dev/null 2>&1 || \
      /usr/bin/hdiutil detach -force "$mounted_device" >/dev/null 2>&1 || true
    mounted_device=""
  fi
  if [[ -n "${stage_root:-}" && "$stage_root" == "$output_root"/.stage-offline.* && -d "$stage_root" ]]; then
    /bin/rm -rf -- "$stage_root"
  fi
  if [[ -n "${mount_root:-}" && "$mount_root" == /private/tmp/identityv-offline-mount.* && -d "$mount_root" ]]; then
    /bin/rm -rf -- "$mount_root"
  fi
}
trap cleanup EXIT INT TERM

/usr/bin/ditto "$source_app" "$app_stage"
"$verify_payloads" --app "$app_stage"

# 使用说明：转成 RTF 让它在 TextEdit 里有基本排版，同时留一份 .md 给维护者和邮件转发。
/usr/bin/textutil -convert rtf -output "$guide_rtf" "$guide_source"
[[ -s "$guide_rtf" ]] || { print -u2 -- "使用说明 RTF 生成失败。"; exit 1; }

# ── 签名、公证 .app ────────────────────────────────────────────────────────────
print -- "④ 由内到外签名并公证 App"
"$runtime_patch_audit" "$app_stage"
# 载荷复核会挂载内嵌的 idv-login 磁盘映像，而 hdiutil 会往映像文件写
# com.apple.diskimages.recentcksum；codesign 对包内带这类扩展属性的文件会整体拒绝
# （"resource fork, Finder information, or similar detritus not allowed"）。
# 扩展属性不属于文件内容，清掉不改变任何已校验的哈希，所以签名前统一清一次。
/usr/bin/xattr -cr "$app_stage/Contents/Resources/OfflinePayloads" 2>/dev/null || true
identityv_sign_bundle_tree "$app_stage"
"$runtime_patch_audit" "$app_stage"
identityv_verify_bundle_tree "$app_stage"
# 载荷复核刻意放在签名**之前**（见上面 ditto 之后那一次）：它要挂载内嵌的 idv-login
# 磁盘映像，而挂载会往映像文件写 com.apple.diskimages.recentcksum。签完名再挂载会给
# 已封存的资源添上新的扩展属性，虽然 codesign 目前仍判有效，但没有理由把这种依赖留在
# 流程里；签名后的完整性由 runtime_patch_audit 与 identityv_verify_bundle_tree 负责。
"$project_root/signing/notarizeIdentityV.command" "$app_stage" --profile "$notary_profile"

IDV_MAX_MACOS_DEPLOYMENT_TARGET=14.0 \
  "$project_root/runtimeManifest/auditMachODeploymentTargets.command" "$app_stage"

# ── 生成 DMG ───────────────────────────────────────────────────────────────────
print -- "⑤ 生成 DMG 并只读复验"
/usr/bin/xcrun swiftc -O -framework CoreGraphics "$dmg_background_generator" -o "$background_generator"
"$background_generator" "$background_pdf"
[[ "$(/usr/bin/head -c 5 "$background_pdf")" == "%PDF-" ]] || { print -u2 -- "背景 PDF 生成失败。"; exit 1; }

"$dmgbuild" -s "$dmg_settings" \
  -D "app=$app_stage" \
  -D "guide=$guide_rtf" \
  -D "background=$background_pdf" \
  "$release_name" "$temporary_dmg"
/usr/bin/hdiutil verify "$temporary_dmg" >/dev/null

/usr/bin/hdiutil attach -readonly -nobrowse -mountpoint "$mount_root" -plist "$temporary_dmg" > "$attach_plist"
mounted_device="$(/usr/bin/plutil -convert json -o - "$attach_plist" | /usr/bin/jq -r --arg mount "$mount_root" '."system-entities"[] | select(."mount-point" == $mount) | ."dev-entry"' | /usr/bin/head -n 1)"
[[ "$mounted_device" == /dev/* && -d "$mount_root/第五人格启动器.app" ]] || { print -u2 -- "DMG 未按预期挂载。"; exit 1; }

mounted_visible="$(/usr/bin/find "$mount_root" -mindepth 1 -maxdepth 1 ! -name '.*' -print | /usr/bin/sed 's|.*/||' | /usr/bin/sort | /usr/bin/tr '\n' ' ')"
[[ "$mounted_visible" == "Applications 使用说明.rtf 第五人格启动器.app " ]] || {
  print -u2 -- "DMG 可见布局不符合预期：$mounted_visible"
  exit 1
}
[[ "$(/usr/bin/readlink "$mount_root/Applications")" == /Applications ]] || { print -u2 -- "Applications 链接无效。"; exit 1; }
[[ -f "$mount_root/.DS_Store" && -f "$mount_root/.background.pdf" ]] || { print -u2 -- "DMG 缺少 Finder 背景元数据。"; exit 1; }
if /usr/bin/find "$mount_root" -mindepth 1 -maxdepth 1 \( -name '.*' ! -name '.DS_Store' ! -name '.background.pdf' -o -name '__MACOSX' \) -print -quit | /usr/bin/grep -q .; then
  print -u2 -- "DMG 含意外的隐藏元数据。"; exit 1
fi
[[ -s "$mount_root/使用说明.rtf" ]] || { print -u2 -- "DMG 内的使用说明为空。"; exit 1; }

/usr/bin/codesign --verify --deep --strict --verbose=2 "$mount_root/第五人格启动器.app"
/bin/zsh "$project_root/gameRunnerApp/tests/microphonePrivacyContract.test.command" "$mount_root/第五人格启动器.app"
# 挂载后的字节复验：证明载荷真的穿过了 DMG 生成与压缩，而不是只在 staging 里对过。
"$verify_payloads" --app "$mount_root/第五人格启动器.app"
"$runtime_patch_audit" "$mount_root/第五人格启动器.app"
IDV_MAX_MACOS_DEPLOYMENT_TARGET=14.0 \
  "$project_root/runtimeManifest/auditMachODeploymentTargets.command" "$mount_root/第五人格启动器.app"

/usr/bin/hdiutil detach "$mounted_device" >/dev/null
mounted_device=""

# ── 签镜像并公证 ───────────────────────────────────────────────────────────────
# 与公开路径同样的原因：Gatekeeper 对 DMG 的评估是 `spctl -t open`，只签名未公证或
# 只公证未签名都会得到 `source=no usable signature`，所以镜像本身也要签、要公证。
print -- "⑥ 签名并公证 DMG"
/usr/bin/codesign --force --sign "$IDENTITYV_RESOLVED_IDENTITY" --timestamp "$temporary_dmg"
/usr/bin/codesign --verify --verbose=2 "$temporary_dmg"
"$project_root/signing/notarizeIdentityV.command" "$temporary_dmg" --profile "$notary_profile"

# ── 发布产物 ───────────────────────────────────────────────────────────────────
/bin/mv -f "$temporary_dmg" "$dmg_path"
/bin/cp "$guide_source" "$guide_copy"
# 说明是要发给别人的文件，显式给普通可读权限，避免继承只读副本上偶然的 0600。
/bin/chmod 644 "$guide_copy"
(
  cd "$output_root"
  /usr/bin/shasum -a 256 "${dmg_path:t}" "${guide_copy:t}" > "$checksums"
)

print -- "离线整包已生成（Developer ID 签名并公证；$IDENTITYV_RESOLVED_IDENTITY）："
print -- "  版本：$release_version（CFBundleVersion $build_number）"
print -- "  安装包：$dmg_path（$(/usr/bin/du -sh "$dmg_path" | /usr/bin/awk '{print $1}')）"
print -- "  使用说明：$guide_copy"
print -- "  校验清单：$checksums"
print -- "  说明：游戏本体不在包内，由用户在启动器里从网易官方下载。"
