# 固定 IDV Login 组件

当前固定上游未修改的 `idv-login` `v6.3.2-stable` 原始 macOS arm64 二进制。唯一发行清单是 `../idvLoginComponent.json`；下载器编译时锁定版本、完整 URL、大小与 SHA-256，测试同时核对启动器的版本/缓存常量，避免只换清单而旧版 UI 仍误判“已安装”。官方 Release 资产为 198,957,312 bytes，SHA-256 `44546da7ec143f73888e8b6e4c4ed53f48d2b03f84c7ca74c20ab8eb310f4045`。

受管 `cloudRes` 外置策略关闭组件自己的升级提示与远程热更新供给，登录云端配置继续工作；组件升级由启动器的固定版本流程管理。helper 只接受精确支持的 `v6.3.2-stable` 构建标识，未知版本 fail closed。控制点、来源审计、私有配置备份与恢复见[来源与更新策略审计](../docs/idvLoginSourceAudit.md)。

维护者已有官方下载成品时，可离线暂存：

```zsh
./stageIdvLoginReleasePayload.command /绝对路径/idv-login-v6.3.2-stable-mac
```

它离线校验精确大小、SHA-256 和 arm64 架构，并写入 Git 忽略、权限 `0700/0600` 的 `releaseCache/6.3.2/`，只用于维护者安装准备。构建 App 不需要这个 cache，也不会从 `/Library` 现有安装或旧 App 提取二进制。

最终 App 的 `InstallerPayload/` 含 manifest、root 安装器、特权 helper 输入、state tool、迁移脚本、预览卸载器和 ThirdPartyNotices，**不含 idv-login 二进制**。用户安装时从固定的上游 Release 下载。

RC1 的 `6.3.0` 到 `6.3.2` 使用现有安装入口：先停止受管后台，再备份配置并隔离旧 Python 热修复覆盖层；新组件落入按版本命名的 `6.3.2` 槽后原子切换 `current`。不能只替换可执行文件：6.3.2 的上游 hook 仍会加载旧配置中标为待验证或已应用的覆盖层。迁移夹具以合成账号、配置和证书资料验证这些非热修复状态保留、旧覆盖层移入可恢复备份、重复同版本迁移不再改写；没有触碰真实账号或安装中的代理。

2026-10-05 更新锁定官方 `v6.3.2-stable`；精确源码 commit `3642748dcf82c326ddb5cb657714be9a0885d7fc`，tag 的 peeled commit 与 GitHub release tag 对应。源 `LICENSE` SHA-256 仍为 `3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986`。资产核验只读完成；未启动二进制、登录代理或做真实账号回归。

默认安装器仍拒绝活动游戏，以免拆除游戏所依赖的代理。维护者已明确确认停止代理、保持游戏时，可使用 `--allow-running-game-with-stopped-proxy`，但必须先通过限定 stop helper 完全停止代理并清理托管 hosts；root 阶段再次核查两项条件，不符合就退出 75。此例外不发给 UI，不退出 Wine 或游戏，也不自动启动新版登录。回退保留旧版本组件槽及迁移器产生的旧配置/热修复备份；旧覆盖层只能随对应旧版本恢复，不能重新覆盖新版模块。

## 用户侧下载缓存

启动器安装时把固定版本下载到用户态的版本缓存槽。下载器先复验已完成文件，兼容复用旧预览版 UUID 槽中通过精确大小、SHA-256 和 arm64 Mach-O 检查的同版成品；未完成的 `.partial` 以 HTTP Range 继续，服务端忽略 Range 时安全从零下载。缓存写入使用进程自动释放的文件锁、`0700/0600` 权限和原子发布，不接受 symlink。

网络中断或安装器失败会保留可续传 partial/已验证成品；成功安装后也保留成品供重新安装。只有用户在管理员授权前明确拒绝本轮安装时，启动器才清理这一稳定槽中的 final 与 partial。
