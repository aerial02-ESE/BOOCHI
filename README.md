# 高云电子音乐系统

Tang Mega 60K NEO Dock 负责实时音频合成、屏幕和88键灯光。88键与 SMK25 均作为 USB-MIDI 键盘接入 FPGA 的 USB Host。手机通过 JDY-31-SPP 连接，支持虚拟琴键、音色及效果参数调节、曲谱导入和跟弹计分。

| 目录 | 内容 |
| --- | --- |
| `fpga/` | Gowin 工程、Verilog RTL、ROM 初始化文件、管脚和时序约束、仿真 |
| `esp32/` | ESP-IDF v5.5.4 固件、USB-MIDI、JDY-31 串口桥、曲谱存储和协议 |
| `android_app/` | Android SPP App 0.10.2、Gradle Wrapper、单元测试和演示曲谱 |

## 系统连线

| 设备或信号 | 连接 |
| --- | --- |
| 88键 USB-MIDI | FPGA USB0 Host |
| SMK25 USB-MIDI 键盘 | FPGA USB Host |
| P4 → FPGA | P4 GPIO26（ATK_MODULE U5 第3脚）→ FPGA Y21 |
| FPGA → P4 计分 | FPGA Y22 → P4 GPIO27（U5 第4脚） |
| JDY-31 TXD / RXD | TXD → P4 GPIO28（P1 第20脚），RXD ← P4 GPIO29（P1 第24脚） |
| RGB 显示 | FPGA 底板 40P LCD 接口，480×272 |
| 左右 WS2812 | W22 → 左灯带 DIN，P17 → 右灯带 DIN，外部供电并与 FPGA 共地 |
| 公共地 | FPGA、P4 与外接模块信号共地 |

FPGA 串口为 1 Mbps、8N1。JDY-31 串口默认 9600、8N1。两个灯带各接45颗、各用44颗。每侧从 DIN 数第1颗熄灭，左侧最远端对应 A0，右侧最远端对应 C8。普通模式松键熄灯，跟弹显示蓝色提示、绿色正确、红色错误。

## 构建和启动

1. **FPGA**。用 Gowin IDE V1.9.12.03 打开 `fpga/tang_mega_60k_spectrum_keys.gprj`，器件为 GW5AT-60B。也可在 `fpga/` 中运行 `gw_sh build_implementation.tcl`。编程器可将生成的 `.fs` 临时加载到 SRAM，或写入外部 Flash。
2. **ESP32**。激活 ESP-IDF v5.5.4，在 `esp32/` 中运行 `idf.py build`。下载和查看启动日志用 `idf.py -p COMx flash monitor`，将 COMx 换为实机端口。默认配置面向 DNESP32P4 v1.x。
3. **App**。配置 JDK 17 或 Android Studio 自带 JBR 和 Android SDK Platform 37。在 `android_app/` 运行 `gradlew.bat assembleDebug testDebugUnitTest`，Unix 使用 `sh gradlew`。安装生成的 APK，在手机蓝牙设置配对 JDY-31-SPP，打开 App 点「连接 JDY-31」。

## 演示操作

- **音色**。App 可选原有模式或88键分区模式。分区时 A0 到 B4 固定钢琴，C5 到 C8 使用所选音色。
- **屏幕**。App 的「屏幕显示」或板载 KEY2 切换频谱和键盘、立体声李萨如、曲谱页面。
- **跟弹**。上传曲谱并等待保存确认，再开始跟弹。按对时间窗口为 ±150 ms，FPGA 通过 Y22 返回实时成绩。
- **验证**。在 `fpga/` 首次用 `vmap -c` 生成本地 ModelSim 配置，再执行 `vsim -c -do "do tests/run_practice_integration.do"` 和 `vsim -c -do "do tests/run_usb88_led_outputs.do"`。在 `esp32/` 执行 `python tests/test_protocol_vectors.py`。

手机→P4 使用 SPP 帧 `A5 5A 01 LEN | payload | CRC16`。P4→FPGA 使用8字节 ControlEvent 和同样的 CRC16/CCITT-FALSE 封装，CRC 覆盖版本、长度和负载，高字节先发。

## 提交与验证状态

提交本目录源码。已生成的 FPGA 位流、ESP32 固件和 APK 可单独附在 GitHub Release。27号 FPGA 位流已通过布局布线与 Flash 写入校验。实体灯带曾报告不亮，现有仿真已验证实体键事件到两路 WS2812 数据及发送时序，实板灯光仍待验收。

测试用 `mutopia-vocalise1.mid` 为 F. Abt 的《Vocalise № 1》，Mutopia 项目标记为公有领域。 [曲目与来源](https://www.mutopiaproject.org/cgibin/piece-info.cgi?id=2247)

清理后复验：ESP-IDF v5.5.4 干净构建通过，Android 离线构建及 35 项单元测试通过，ModelSim 跟弹集成与双灯带时序测试通过。FPGA 综合输入与已验证位流的源码逐文件一致。
