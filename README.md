# HSend

HSend 是用 ArkTS 和 ArkUI 编写的 HarmonyOS 局域网文件传输客户端。首版对照 LocalSend 1.19.0 的 v2.2 协议实现 IPv4 设备发现、HTTPS 注册和文件上传。接收前需要确认，已收文件保存在应用内，可从接收记录通过系统文件选择器导出。

主页沿用 LocalSend 的接收、发送、设置三个标签。外屏使用底部导航，窗口达到 700 vp 时切换为侧栏，达到 800 vp 时展开文字标签。界面使用系统符号、白色或黑色底色和靛蓝色强调色。

## 构建与运行

在 DevEco Studio 中打开项目根目录并运行 entry。项目使用 Stage 模型，编译 SDK 为 26.0.0，最低 API 为 20。真机安装需配置本机调试签名。首次构建需要 DevEco Native SDK 和网络连接。CMake 下载 Mbed TLS 3.6.8 发布包并验证固定的 SHA-256。

已配置 DevEco 命令行环境时，可在项目根目录运行以下命令。

```powershell
ohpm install
hvigorw --mode module -p module=entry@default assembleHap
hvigorw --mode module -p module=entry@default test -p coverage=false
hvigorw --mode module -p module=entry@ohosTest assembleHap
```

无签名配置时，主包位于 `entry/build/default/outputs/default/entry-default-unsigned.hap`。本机 Pura X Max 模拟器支持安装调试用未签名包。安装主包和测试包后，用以下命令运行设备测试。

```powershell
hdc shell aa test -b com.hsend.client -m entry_test -s unittest OpenHarmonyTestRunner -s timeout 10000
```

## 验证记录

2026 年 11 月 25 日使用 Pura X Max 模拟器和 Windows 上从上游提交 `44f48f18` 构建的 LocalSend CLI 1.19.0 测试。两端通过 HDC 端口映射建立真实 HTTPS 连接。

| 场景 | 结果 |
| --- | --- |
| 官方 CLI → HSend → 系统导出 → 官方 CLI | 同一份 256 字节文件往返成功，两端 SHA-256 均为 `40AFF2E9D2D8922E47AFD4648E6967497158785FBD1DA870E7110266BF944880` |
| HSend → 官方 CLI | 64 MiB 文件发送完成，原件和接收件 SHA-256 均为 `3B6A07D0D404FAB4E23B6D34BC6696A6A312DD92821332385E5AF7C01C421351` |
| 折叠与展开 | 外屏待确认请求切到内屏后仍可接收；系统选择器返回后的已选文件随导航切换保留 |
| 本地与设备测试 | 3 项本地测试、10 项设备测试通过，覆盖布局断点、分块解析、接收确认、取消、校验失败与存储恢复 |
| 官方 CLI → HSend，64 MiB 与空文件批次 | 旧接收实现返回 HTTP 500，失败文件被丢弃。修复后的真机结果见下文 |

### Pura X Max 真机

2026 年 11 月 26 日，在 Pura X Max 典藏版（HOP-AL10，HarmonyOS 7.0.0.111，API 26）上安装了 HSend 调试签名包。USB 用于安装和观察界面，文件传输直接走 Wi-Fi。

- 接收页在内屏和外屏均将接收记录、连接信息放在内容区右上角，距上边和右边各 16 vp。真机点击两个入口均能打开对应页面。
- 同一局域网的 Windows LocalSend CLI 1.19.0 发现了真机。256 字节文件经真机接收、系统导出、重新选择后发回 Windows，原件与回传件 SHA-256 均为 `40AFF2E9D2D8922E47AFD4648E6967497158785FBD1DA870E7110266BF944880`。修复前，64 MiB 分块上传在真机接收至 16 MiB 时返回 HTTP 500。
- 为区分 HTTP 分块解析与接收字节流，使用固定 `Content-Length` 发送 32 MiB 带连续序号的数据，TLS 记录大小为 8 KiB。真机收到全部字节，但 SHA-256 校验失败并返回 HTTP 422。写盘前的三个连续回调本应依次来自原文件偏移 1,073,152、1,081,344、1,089,536，实测顺序为 1,081,344、1,089,536、1,073,152。

### 大文件接收修复与复测

入站 HTTPS 通过 Native API 调用 Mbed TLS，由 ArkTS 按 HTTP 消费速度顺序读取，每个连接最多预读一个 16 KiB 数据块。ArkTS 继续处理 LocalSend 协议、设备证书指纹、接收确认与文件保存。

| Pura X Max 真机经 Wi-Fi 接收 | 验证结果 |
| --- | --- |
| 32 MiB 连续序号文件，固定 Content-Length | 默认 TLS 记录和 8 KiB 记录分别测试，上传均返回 HTTP 200。手机校验落盘文件的 SHA-256，均为 `c4744935e8653e85eaee99253e7982fbf265d0673bd0303b3b3a11f30feb382f` |
| Windows 官方 CLI 1.19.0 分块上传 64 MiB 连续序号文件与一个空文件 | 两个文件均接收完成。64 MiB 文件经系统导出并发回官方 CLI，原件与回传件的 SHA-256 均为 `d5f530811c8d9d406ad550cfcda607b89df0716df2e0561686c46283f4a1f3bd` |
| 真机 Hypium | 11 项通过，含新增的按需预读、跨记录分块与流结束回归用例 |

Windows 图形客户端、断网恢复和正在传输时的真机开合仍待验收。
