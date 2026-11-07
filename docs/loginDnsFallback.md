# IDV Login：公网 UDP DNS 受阻时的有界 TCP 回退

2026-11-07：正式维护实现已进入本工作树并通过隔离测试；系统 helper 与活动登录代理尚未由本任务替换。11 月 6 日的实机恢复使用临时完整模块和启动 hook，不能作为本次正式实现已部署的证据。

## 问题、来源与版本归因

国服标题页收到点击后，游戏尝试 SDK 登录，返回 220 并重置标题页；组件同期记录 `sauth.response network_reason=tls http=None`。220 在这里只是观察到的 SDK 结果，不泛化为所有 220 的原因。

官方 v6.3.3-beta 固定提交 [0cee1f6b 的 mitm_proxy.py](https://github.com/KKeygen/idv-login/blob/0cee1f6b5c03b93d999a94bfc6e4baf745456d1b/src/mitm_proxy.py) 对非硬编码域名仅查询四个公网 UDP DNS。故障网络中 UDP 查询超时，认证域名 `mgbsdk.matrix.netease.com` 未写入真实 IP 缓存，却仍加入受管 hosts；转发时系统解析可能回到本地代理。现场无凭据 GET 经代理返回 502/证书链错误，同域名 TCP DNS 和 DoH 成功，保留 SNI 与证书验证直连真实地址得到 200，其他已缓存域名经代理也正常。证据支持“解析失败 → 回环 → TLS 失败”，尚未定位哪个网络设备阻挡 UDP。

官方 v6.3.2-stable 与 v6.3.3-beta 的 main.py 都已有该认证域名拦截，mitm_proxy.py 都已有公网 UDP 依赖；不能称为 6.3.3 新增回归，也没有依据给出发生概率。旧版在相同条件下也可能触发，但未进行旧版实机对照。

正式适配仅接受官方 6.3.3 macOS arm64 资产：199,215,712 bytes，SHA-256 `dcfef8ddd66fae454d30c296dbdc42496a862ed38cd533e0b4b8032b5db9cac5`。对应上游网络模块源码 SHA-256 为 `76db39b43920e0f5ffc32cfd101c22717c2c04baa8dc9c86f11a69f4d1c1f47e`。版本字符串、helper 合约号或路径名称均不能代替字节身份。

## 正式实现与维护生命周期

- 唯一适配源码为 [dnsTCPFallback.py](../idvLoginComponent/dnsTCPFallback.py)。[原生工具构建入口](../privilegedHelpers/buildIdentityVPrivilegedStateTool.command) 将其嵌入原生 executable，运行时不依赖系统 Python，也不需要安装独立脚本载荷。构建同步执行协议测试。
- [start helper](../privilegedHelpers/start-idv-login.sh) 在共享生命周期锁内先检查进程；仅代理未运行时准备目录、配置、覆盖层及 hosts，然后启动。已有代理不会因重复 start 而被改写配置或补丁；新源码要在下一次正常停止/启动后加载。原生 `prepare-config` 还独立拒绝活动代理，避免其他调用者误写。
- [原生状态工具](../privilegedHelpers/IdentityVPrivilegedStateTool.swift) 对实际组件流式校验大小和 SHA-256，按既有原子写规则生成 root-owned、0600 的 `launcher-dns-tcp-633-v1.py`，再发布 config 引用。适配记录 ID 为 `launcher-dns-tcp-fallback-v1`，含项目 owner、固定 target、来源摘要；保留账号、其他配置与无关 hotfix/pending 记录。配置写失败时最多遗留无引用源码，不会先发布缺失/半写文件的引用。
- 覆盖层导入时再次流式核对 `sys.executable` 的同一精确大小/摘要。上游若自行更新并重启、绕过 helper 准备，遗留记录只加载新原模块，保留其原入口而不安装替换。原解析函数用 `globals().get` 捕获；只有精确身份和所需函数/上游列表能力都匹配才在末尾赋值覆盖，不假定未知版本仍有解析入口或 logger；适配专用标准库依赖也仅在受支持分支加载。
- 覆盖层沿用上游 [hotfixmgr 的外置模块 hook](https://github.com/KKeygen/idv-login/blob/0cee1f6b5c03b93d999a94bfc6e4baf745456d1b/src/hotfixmgr.py)。它通过 `PathFinder` 绕过该 meta finder，要求得到 `pyimod02_importers.PyiFrozenLoader`，取原模块 code 并在当前模块 namespace 执行。原类、函数 globals、缓存与代理实现保持同一模块身份，仅替换 `_query_upstream_parallel`；不复制上游完整模块，不替换证书/TLS实现。
- 仅三个既有受管认证域名启用适配：`service.mkey.163.com`、`sdk-os.mpsdk.easebar.com`、`mgbsdk.matrix.netease.com`。其他域名委派原函数。仍向原模块的同组上游并行查询，UDP 成功直接使用；超时、截断或无有效地址才向同一服务器发 TCP 查询。不固定瞬时网易 IP。
- DNS 验证包括事务 ID、QR、opcode、TC、RCODE、问题数量/名称/类型/类别、报文与压缩指针边界、CNAME 链及 A/IN 归属；拒绝回环、未指定、链路本地、多播和广播地址。TCP 按两字节长度前缀完整读取，整个连接/发送/读取共用约 2 秒截止时间，不因分段到达而无限续时；UDP 单次等待约 2 秒。所有服务器失败返回 `None`，不让外层 future timeout 异常逃逸到认证流程。

已有其他 `applied` 或 `pending_validate` 的 `mitm_proxy` 热修复时，正式准备失败并保留原记录，交维护者核对合并或上游退出条件，不静默覆盖。结构异常的 `hotfix_records`、同名受管记录身份冲突、覆盖层符号链接或异常权限也拒绝写入。

## 临时修复迁移、退出与撤销

11 月 6 日临时恢复的完整派生模块 SHA-256 为 `5557e14a16f9789ead154e7ab721b31b3462d93f1eeb7f069461e628ee11ffce`。正式状态工具只在 `dns-tcp-fallback` 记录的模块、kind、用户状态目录内固定路径以及实际文件所有者/权限/此摘要全部匹配时，将该已知临时记录替换为正式记录；其他同名或修改过的文件不视为已知临时修复。旧源码不自动删除，以免碰用户文件；记录退出后不会加载它。

旧系统状态工具曾在 `prepare-config` 清掉全部 hotfix，导致临时补丁首轮未加载。随后在 root start-helper 后置注册 hook 才恢复。正式实现由原生准备步骤直接管理登记，并保留无关 hotfix；部署必须整体替换旧 helper/状态工具，不能保留后置 hook 叠层。旧 helper 合约号相同不代表代码相同。

停止代理后，配置中设置布尔值 `launcher_dns_tcp_fallback_disabled: true`，下一次正式启动准备将只移除此项目适配记录（以及可证实归属的旧临时记录），保留其他 hotfix、账号及后续配置。删除该开关或设为 false 可在精确支持版本恢复适配。组件大小/摘要变化时同样退出本项目覆盖层；新版本必须先审计上游 DNS 与冻结加载契约，不能仅放宽 hash 门。若上游已修复，在源码移除登记入口并清理本项目记录后即可退役。

## 已完成验证

2026-11-07，均未停止活动代理、修改系统 helper、操作账号或启动官方代理 binary：

1. 原生工具实际编译、签名及 macOS 14 deployment 审计通过。自检覆盖跨流式块的正确/错误摘要与大小、重复配置准备、账号/其他 hotfix/pending 保留、版本变更退出、显式退出、同模块冲突与源码 symlink 拒绝。
2. [DNS 协议测试](../idvLoginComponent/dnsTCPFallback.test.py) 9 组通过，使用本地真实 UDP/TCP socket 验证 UDP 成功不走 TCP、UDP 超时/无效响应后回退、分段长度与正文完整读取、截断/损坏/缓慢 trickle 的失败和总时限；协议用例覆盖问题/ID/标志、压缩越界/循环、CNAME、无关 A 与回环拒绝，以及非受管域名原函数委派。另以缺失 query/logger/构造函数/上游列表的未知模块 fixture 验证透明加载、原 namespace 保留和能力不足时不安装覆盖；真实冻结探针断言未知资产保留原查询函数身份。
3. [readiness/lifecycle 测试](../privilegedHelpers/idvLoginReadiness.test.command) 与 [launchd 测试](../privilegedHelpers/idvLoginJob.test.command) 通过；执行真实生产 start 分支配合无副作用替身，确认已有代理不准备配置/目录/hosts，停止状态按目录 → 原生准备 → hosts → start 排序。
4. [真实冻结加载探针](../idvLoginComponent/dnsFrozenProbe.py) 使用 Python 3.12.16 / PyInstaller 6.16.0 构建并运行 onefile，冻结精确上游完整网络模块，再经上游同形 finder 加载完整未改适配源码。原类身份、原函数 globals、真实 IP 缓存与 `resolve_domain_ip` 到新函数的委派通过；先断言合成 binary 被运行时版本门拒绝，再由探针在内存中开启受支持分支验证委派。仅环境/日志入口使用无副作用替身，未创建代理。构建产物自动清除。现装官方资产只读检查确认 Python cookie 312，且含 `mitm_proxy`、`ipaddress`、`concurrent.futures`、`importlib.machinery`。这验证真实冻结加载机制，不冒称已在正式官方进程内验收。
5. 对现装精确官方资产的只读测试确认运行时摘要门接受它（未执行该 binary）。当前网络对受影响认证域名的无凭据 DNS 实测约 2.01 秒获得非回环 A 地址。它不替代经正式代理的 TLS/认证验收。

复现命令（从仓库根目录；冻结探针需独立 Python 3.12 环境安装 PyInstaller 6.16.0，可传 `--upstream-source` 使用摘要一致的缓存）：

```sh
zsh privilegedHelpers/buildIdentityVPrivilegedStateTool.command
zsh privilegedHelpers/idvLoginReadiness.test.command
zsh privilegedHelpers/idvLoginJob.test.command
python3.12 idvLoginComponent/dnsTCPFallback.test.py
/path/to/probe-venv/bin/python idvLoginComponent/dnsFrozenProbe.py
```

## Lead 部署与实机验收

代码审核后，由 Lead 统一 helper 合约/版本、正式 App 构建和安装，使用既有组件/helper 安装入口部署，核对新状态工具与 start-helper 的实际摘要；不要仅检查合约号。更新准备本身保留当前现场，在明确安排的停止窗口停止精确登录 job，再整体替换旧 helper 与状态工具，使临时后置 hook 随旧 helper 退出。不要在本任务运行中覆盖组件文件。

首次正常启动后检查：正式记录唯一存在，旧临时登记已退役，其他 hotfix/账号保持，日志出现 `IDV launcher DNS TCP fallback active (official 6.3.3)`；活动 start 不改变配置/补丁，再正常停止并启动一次，确认登记和源码重复准备稳定。若冲突或加载失败，保留错误，停止代理后按退出开关移除此项目适配；不恢复整份旧 config 覆盖新账号状态。

最后分层验收：受影响域名经代理无凭据 GET 的原 502 变为正常 200且上游 TLS 验证仍保持；真实 SDK SAUTH 成功/回调 0；用户实际进入大厅。需游戏或用户操作时由 Lead 协调。11 月 6 日临时方案已完成这三项，正式实现的SDK认证/大厅复验仍待接续；CLI ready、独立 DNS 结果或冻结探针成功均不单独代表认证成功。

### 2026-11-07 本机部署进展

由完整构建通过的开发包更新原有helper及状态工具至维护合约11，正式覆盖层登记存在，已知临时登记退出。已装与新包start脚本SHA256相同，原生状态工具均严格验签且CodeDirectory相同（完整文件SHA不同，被签名代码目录一致），不是仅凭合约号认定更新。服务ready，无凭据受管域名HTTPS从代理返回200且未关闭证书验证，日用build26/27的CLI已运行分支返回成功。

部署验收脚本把组件自己的启动时间戳也列为不变条件，导致服务已就绪后最终配置比对报错；只读核对确认主配置差异仅为`last_run_state_ts`。其他hotfix登记差异及已不被引用的旧临时文件归档仍等待该次系统授权完成，不恢复整份旧配置，也不提前宣称所有登记/账号验收已通过。代码不因此回滚；最终SDK认证与大厅证据仍按上一段要求单列。
