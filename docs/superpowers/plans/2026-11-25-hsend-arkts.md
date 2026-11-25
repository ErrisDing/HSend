# HSend ArkTS 客户端实施计划

> 执行技能采用 `superpowers:executing-plans` 或 `superpowers:subagent-driven-development`。按任务勾选并记录验收结果。

**目标**　在 Pura X Max 上与 Windows 官方 LocalSend v1.19.0 双向收发文件，开合屏幕时继续当前操作。

**本轮验收**　Pura X Max 模拟器已与上游 Windows CLI 双向传输并核对哈希。64 MiB 文件发送通过，接收方向仍有可复现的分块错误。实测条件与结果见[验证记录](../../../README.md#验证记录)。未勾选项包含尚待真机验证的工作。

**架构**　应用级 ArkTS 对象持有设备身份、发现监听和传输会话。ArkUI 订阅会话状态，选择器提供文件 URI，传输层按块读写。首个里程碑贯通单文件发送和接收，之后扩展多文件、恢复处理和折叠屏体验。

**技术**　HarmonyOS Stage 模型、ArkTS、ArkUI、Network Kit、Crypto Architecture Kit、Core File Kit、Hypium、Hvigor。

**设计依据**　[HSend 首版设计](../specs/2026-11-25-hsend-harmonyos-design.md)，提交 `595a31a`。参考仓库为本机 `S:/GitHub/localsend` 的 `44f48f18`，其 `app/pubspec.yaml` 标明应用版本为 1.19.0+65。

## 全局约束

- 兼容 IPv4、LocalSend v2.2 和 HTTPS，组播为 `224.0.0.167:53317`，本机 HTTPS 监听端口为 `53317`。Windows 验收端启用加密，关闭接收 PIN。
- 每次接收须经用户确认。同一时间最多一个待确认或活动的接收会话。用户文件、安装身份和临时传输数据分别管理。
- 主页沿用 LocalSend 的接收、发送、设置顺序和导航断点。白底、黑底与靛蓝强调色配合系统图标，ArkUI 使用 `SymbolGlyph`。典型窗口为外屏 459 × 672 vp、内屏 939 × 664 vp。
- 记录实际 SDK、构建工具、设备系统和对端版本。构建用本机 DevEco Studio 的 SDK；兼容 API 取决于所用接口及目标机系统。签名私钥和真机授权保存在开发机。

## 重点复核

| 条件 | 预期结果 | 对应任务 |
| --- | --- | --- |
| 已发现设备的证书改变 | 在发送请求正文前结束连接 | 1 |
| 重复公告、本机回环公告或更换 Wi-Fi | 设备去重，重新绑定后能继续发现 | 2 |
| 上传以 chunked 编码送达，或 TCP 分片恰好落在头部中间 | 按 HTTP 消息边界还原，文件字节数和哈希一致 | 2、3 |
| 多文件并发写入、重复令牌、取消与保存同时发生 | 每个文件最多落盘一次，保留完成项，释放接收会话 | 4 |
| 待确认、选文件返回或传输中跨过导航断点 | 仍是同一次操作，接收请求只回答一次 | 5 |

## 文件与验证入口

以下 `ets/` 指 `entry/src/main/ets/`，`test/` 指 `entry/src/test/`。创建工程时保留 DevEco Stage 模板的构建文件和测试入口，把每个本地测试套件登记到 `entry/src/test/List.test.ets`。

| 文件 | 职责 |
| --- | --- |
| `ets/entryability/EntryAbility.ets`、`ets/app/AppSession.ets` | 应用生命周期、订阅和当前会话 |
| `ets/network/Identity.ets`、`ets/network/TlsTransport.ets` | 安装身份、TLS 监听、同一连接的对端证书验证 |
| `ets/network/Discovery.ets`、`ets/network/HttpConnection.ets`、`ets/model/Protocol.ets` | 发现、HTTP 消息边界、v2 DTO 和路由 |
| `ets/transfer/Transfers.ets`、`ets/storage/ReceivedFiles.ets` | 发送与接收状态、文件存取、完成记录和导出 |
| `ets/pages/Index.ets` | 首页标签、当前会话、已收文件 |

在项目根目录运行以下 PowerShell 命令。后文的“单测”和“构建”分别指 `test` 和 `assembleHap` 两条命令。单测须报告预期用例通过且无失败，构建须退出码为零并生成 entry HAP。

```powershell
$hsHvigor = 'D:/PROGRAMMES/DevEco Studio/tools/hvigor/bin/hvigorw.bat'
$hsHdc = 'D:/PROGRAMMES/DevEco Studio/sdk/default/openharmony/toolchains/hdc.exe'
& $hsHvigor --mode module -p module=entry@default test
& $hsHvigor --mode module -p module=entry@default assembleHap
& $hsHdc list targets
```

### 1. 在真机建立可验证的 TLS 连接

- [ ] 建立 Stage 工程、entry 模块和最小接收页。配置 `entry/src/main/module.json5` 的网络权限。构建并在目标机启动，记录设备 API、签名安装结果和构建版本。
- [ ] 在 `test/Identity.test.ets` 加入固定 DER 样本的指纹测试。用 Windows `Get-FileHash -Algorithm SHA256` 独立生成样本期望值。先运行单测，确认失败位置为缺少指纹实现。
- [x] 在 `Identity.ets` 实现 `fingerprint(der: Uint8Array): Promise<string>` 和 `loadOrCreateIdentity(context: common.UIAbilityContext): Promise<DeviceIdentity>`。DeviceIdentity 包含私钥 PEM、证书 PEM 和大写十六进制指纹。对照上游 `packages/core/src/crypto/cert.rs` 生成每安装唯一的自签名身份，持久化完整配对。导入已有证书的 API 与签发新证书的能力分别验证。
- [x] 在 `TlsTransport.ets` 实现 `connectPeer(peer: Peer, identity: DeviceIdentity): Promise<VerifiedConnection>` 与服务端连接处理。Peer 包含 IPv4 地址、端口、别名和指纹；VerifiedConnection 仅在本连接完成证书校验后交给 HTTP 层。验证 Network Kit 的 `TLSSocket` 和 `TLSSocketConnection.getRemoteCertificate()` 在收发两个方向均能取得实际对端证书。
- [ ] 跑单测和真机握手。验证同一安装重启后指纹相同、两个安装指纹不同、指纹不符时应用层发送字节数为 0。记录双方呈交的证书，与官方客户端实际连接复核。若目标 SDK 无法处理陌生设备自签名客户端证书，保留最小复现和系统错误码，按设计评审传输层选择。
- [ ] 提交可构建的工程、安装身份与 TLS 验证。

### 2. 发现官方设备并注册

- [ ] 在 `test/Discovery.test.ets` 先测连续两次公告产生一个设备、自身指纹产生零个、回复包不再触发回复。在 `test/HttpConnection.test.ets` 测跨包请求行、头部终止符和同一连接上的连续请求。跑单测记录失败。
- [x] 在 `HttpConnection.ets` 为已验证连接提供 HTTP/1.1 请求和响应读写。按头部、内容长度或 chunked 分帧，限制控制 JSON 和头部大小，上传正文使用流。在 `ProtocolV2.ets` 定义设备和注册 DTO，字段拼写与上游 `packages/core/src/http/dto_v2.rs` 一致。
- [x] 在 `Discovery.ets` 实现 `start(identity: DeviceIdentity): Promise<void>`、`refresh(): Promise<void>` 和 `stop(): Promise<void>`。先启动 HTTPS 监听，再加入组播并发公告。收到公告后以来源地址和公告端口注册，兼容 UDP 回复，按证书指纹去重。网络切换时清除旧绑定和过期地址。
- [ ] 通过 `EntryAbility.ets` 初始化唯一 AppSession；最小页面显示本机身份、可选设备和刷新操作。跑单测、构建。真机与官方客户端分别先启动，检查双方均能发现对方，刷新无重复，切换 Wi-Fi 后可重新发现。
- [ ] 提交可互相发现的客户端。

### 3. 完成首个里程碑，双向传一个文件

- [ ] 在 `test/Transfers.test.ets` 先测确认、拒绝和零字节文件。断言确认前发放令牌数为 0，接受后仅获准文件得到令牌，拒绝返回 403。补上分块正文含中文文件名、跨块数据和结束块的样本，断言接收字节等于原件。
- [x] 在 `Transfers.ets` 提供 `sendFiles(peer: Peer, uris: string[]): Promise<void>`、`answerReceive(accepted: boolean): void`。先贯通一个 URI，发送前取得文件名、MIME 和字节数。实现 `prepare-upload` 和 `upload`，按证书身份、来源地址、会话 ID、文件 ID 和令牌绑定请求。文件流读写均等待下游完成后再读下一块。
- [x] 在 `ReceivedFiles.ets` 以内部生成的文件标识写应用私有临时文件，限制保存范围并保留同名文件。完成时校验字节数及对端提供的 SHA-256，失败清理临时文件，哈希不符返回 422。完成文件与接收记录须可在重启后核对和恢复。
- [x] 在最小 ArkUI 页面接通系统文档选择器、设备选择、接收确认和当前文件进度。完成页使用系统保存选择器与 `ReceivedFiles.ets` 的 `exportReceived(id: string, destinationUri: string): Promise<void>` 导出单文件，供两端校验。将确认请求保存在 AppSession，连接结束后撤回对应请求。
- [ ] 跑单测、构建。在 Pura X Max 与 Windows 官方客户端之间分别发出和收到同一份文件，导出后用 `Get-FileHash` 比对原件。记录两个方向的文件大小、SHA-256、两端版本和网络环境。两个方向都通过才记为首个里程碑完成。
- [ ] 提交已验证的单文件传输闭环。

### 4. 多文件、取消、导出与恢复

- [ ] 扩展 `test/Transfers.test.ets` 和 `test/ReceivedFiles.test.ets`。覆盖部分接受仅上传已返回令牌的文件、同时接收两个文件、重复上传同一文件、等待确认期间对端退出、同名文件冲突以及取消与写入完成的竞争。
- [x] 扩展 `sendFiles` 为逐文件发送，接收方允许同一会话内不同文件并行，原子占用每个文件的令牌。整批确认只回答一次；另一会话在待确认和活动期均返回 409。用每文件和总进度驱动 TransferPage。
- [x] 实现 `cancelTransfer(): Promise<void>`。发送端拿到会话 ID 后调用 `cancel`；等待确认时中止对应请求。接收端主动取消时终止会话连接。对取消、断连、超时和存储失败统一释放会话，保留已完成文件。
- [ ] 在 `HistoryPage.ets` 复用完成页的导出操作。验证用户取消导出后还能重试，重启后可找到并导出已收文件。
- [ ] 跑单测、构建，用官方客户端收发含空文件、同名文件和大于可用应用堆内存的文件批次。记录大文件峰值内存及哈希；中途断网、两端分别取消后各发起一次新会话。
- [ ] 提交多文件与恢复处理。

### 5. 完成原生主页和 Pura X Max 开合验收

- [ ] 在 `test/HomeLayout.test.ets` 固定断点行为，699 vp 为底部导航，700–799 vp 为紧凑侧栏，800 vp 起为展开侧栏。以 `entry/src/ohosTest/ets/test/HomeContinuity.test.ets` 检查宽度变化后会话 ID、当前标签和确认调用次数。
- [x] 按上游 `app/lib/pages/home_page.dart`、`pages/tabs/` 和 `widget/responsive_builder.dart` 完成 Index。默认接收；发送页上方选择文件，下方列出设备；设置页提供主题与设备名称。系统选择器返回和窗口重排均复用已有 AppSession。
- [x] 使用设计规定的八个 `sys.symbol` 资源，给仅图标按钮提供中文无障碍名称。使用白底 `#FFFFFF`、黑底 `#000000`，浅深主题强调色分别为 `#4343CA`、`#A3A6FF`。持久化跟随系统、浅色和深色选择。
- [ ] 跑单测和构建，在设备上运行 HomeContinuity 测试套件。分别在待发送、待确认、实际大文件传输中双向开合。核对操作只执行一次、进度持续、最终哈希相同。检查两套主题、长文件名和系统安全区下的按钮。
- [ ] 提交布局与验收记录。在最终交付中区分已通过的单测、构建、模拟器结果和 Pura X Max 实测，并列明未执行的项目及原因。
