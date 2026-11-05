# IDV Login 固定组件

当前固定上游未修改的 `v6.3.3-beta` macOS arm64 资产，不随 App 重分发。官方资产为 199,215,712 bytes，SHA-256 `dcfef8ddd66fae454d30c296dbdc42496a862ed38cd533e0b4b8032b5db9cac5`；精确源码为 `0cee1f6b5c03b93d999a94bfc6e4baf745456d1b`。6.3.3 当前发布通道是 beta，不虚构 stable 标签。

唯一发行清单是 `../idvLoginComponent.json`；Go 下载器、Swift UI/cache、离线准备入口与许可来源同步锁定。维护者可运行 `./stageIdvLoginReleasePayload.command /绝对路径/idv-login-v6.3.3-beta-mac` 校验大小、哈希与架构，写入忽略的 `releaseCache/6.3.3/`，构建不需要此缓存。

helper 合约为 10，精确版本门改为 6.3.3 beta。启动准备移除历史 launcher-pinned-update-policy 记录，保留上游更新和其他 overlay；版本提示不再作为已安装或可操作条件。跨版本安装继续隔离旧 overlay、保存账号、配置和证书，并原子切换版本槽；安装前退出活动代理。兼容性检查与真实测试边界见 [来源审计](../docs/idvLoginSourceAudit.md#633-beta-来源与兼容性2026-11-05)。

## 升级、回退与用户侧下载缓存

默认安装器拒绝活动游戏。已明确安排保留活动游戏的维护更新可使用 `--allow-running-game-with-stopped-proxy`，但必须先通过 stop helper 停止代理并清理托管 hosts；root 阶段再次复核。该例外不提供给 UI，不自动启动新版组件。回退保留旧版本槽和迁移器产生的旧配置/热修复备份；旧覆盖层只随对应旧版本恢复，不能覆盖新版模块。最终 App 的 InstallerPayload 包含清单、安装器、helper 与迁移工具，不包含组件二进制。

用户态版本缓存复用通过精确大小、SHA-256 与 arm64 检查的同版成品；partial 以 HTTP Range 续传，服务端忽略 Range 时从零下载。缓存保持文件锁、0700/0600 权限与原子发布，不接受符号链接。网络或安装失败保留缓存；成功安装也保留同版成品供重新安装，只有用户在管理员授权前明确拒绝本轮安装时才清理该版本缓存。
