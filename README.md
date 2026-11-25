# HSend

HSend 是用 ArkTS 和 ArkUI 编写的 HarmonyOS 局域网文件传输客户端。首版对照 LocalSend 1.19.0 的 v2.2 协议实现 IPv4 设备发现、HTTPS 注册和文件上传。接收前需要确认，已收文件保存在应用内，可从接收记录通过系统文件选择器导出。

主页沿用 LocalSend 的接收、发送、设置三个标签。外屏使用底部导航，窗口达到 700 vp 时切换为侧栏，达到 800 vp 时展开文字标签。界面使用系统符号、白色或黑色底色和靛蓝色强调色。

## 构建与运行

在 DevEco Studio 中打开项目根目录并运行 entry。项目使用 Stage 模型，编译 SDK 为 26.0.0，最低 API 为 20。真机安装需配置本机调试签名。

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
| 官方 CLI → HSend，64 MiB 与空文件批次 | 大文件上传返回 HTTP 500。已复现分块解析失败，进度停在 512 KiB 或 1 MiB；失败文件被丢弃。大文件接收仍在排查 |

实体 Pura X Max 与 Windows 图形客户端在同一 Wi-Fi 上的组播发现、断网恢复和开合屏传输仍待验收。已有设备建立双向 TLS 后，新设备若只发 HTTPS 注册，可能需要在新设备端刷新以发出组播公告。
