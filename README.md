# HSend

HSend 是用 ArkTS 和 ArkUI 开发的 HarmonyOS 局域网文件传输客户端，按 LocalSend v2.2 协议发现同一 IPv4 局域网内的设备，并通过 HTTPS 收发文件。接收方确认后，文件保存在应用内，可从接收记录导出到系统目录。

界面适配 Pura X Max 内外屏。窄屏使用底部导航，宽屏使用侧栏，支持浅色和深色主题。

## 构建与运行

1. 在 DevEco Studio 中打开项目根目录。项目目标 SDK 为 `26.0.0`，最低支持 API 20。
2. 安装对应的 Native SDK。首次构建需要联网，CMake 会下载 Mbed TLS 3.6.8 并校验 SHA-256。
3. 连接 HarmonyOS 真机并配置本机调试签名，选择 `entry` 模块后运行。

如已配置 DevEco 命令行工具，可在项目根目录构建 HAP：

```powershell
ohpm install
hvigorw --mode module -p module=entry@default assembleHap
```

主包输出到 `entry/build/default/outputs/default/`。配置调试签名后，可用 `hdc install -r entry/build/default/outputs/default/entry-default-signed.hap` 安装到已连接的设备。

## 运行测试

运行本地单元测试：

```powershell
hvigorw --mode module -p module=entry@default test -p coverage=false
```

在已安装主包的真机上运行 Hypium 测试：

```powershell
hvigorw --mode module -p module=entry@ohosTest assembleHap
hdc install -r entry/build/default/outputs/ohosTest/entry-ohosTest-signed.hap
hdc shell aa test -b com.hsend.client -m entry_test -s unittest OpenHarmonyTestRunner -s timeout 10000
```

[待验证事项](TODO.md)
