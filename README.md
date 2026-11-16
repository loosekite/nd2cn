# nd2cn — MX-5 ND2 中国大陆车主车机自定义工具包

适用车型：2022 墨西哥版 Mazda MX-5 ND2 (RF)  
适用固件：Mazda Connect Gen6 74.00.324 / 74.00.324A  
平台：Visteon CMU, NXP i.MX6, Linux 3.0.35

## 功能概览

**默认安装（插入 USB 即执行）：**
- 启用简体中文界面 + 公里/摄氏度
- 修复原厂翻译错误（RBDS 流派错位、安全功能名称中文化等）
- 提升 UI 响应速度（Opera 缓存、CPU 优先级调整）
- CarPlay/Android Auto 提到菜单首位
- 启动免责弹窗加速（3.5s → 0.2s）
- 启用北斗卫星定位（GPS+BeiDou，替代 GPS+GLONASS）
- 清除北美 GPS 星历缓存（加速中国首次定位）
- 联系人拼音排序规则
- USB 音乐元数据长度限制提高（128→256，中文歌名不截断）

**可选安装（从 `plugins/optional/` 移到 `plugins/` 即启用）：**
- 行车触屏解锁
- SSH 远程访问
- 自定义 DSP 均衡器
- 赛道实时仪表 App（G 力、车速、RPM、油门/刹车、水温）
- 无线 CarPlay 防火墙端口（实验性）
- 蓝牙音频延迟优化
- 开机动画跳过
- FLAC 格式兼容性检测

## 使用方法

### 准备工作

**你需要：**
- 一张 4GB 以上的 USB 闪存盘
- 一台运行 Linux 或 macOS 的电脑（Windows 也可以，但需要特殊工具创建触发文件）
- 你的 MX-5 ND2（发动机需要运行以保证稳定供电）

### 第一步：格式化 USB 盘

将 USB 盘格式化为 **FAT32**，使用 **MBR 分区表**（不是 GPT）。

```bash
# Linux（替换 /dev/sdX 为你的 USB 设备）
sudo mkfs.vfat -F 32 /dev/sdX1

# macOS
diskutil eraseDisk FAT32 ND2CN MBRFormat /dev/diskN
```

### 第二步：复制文件到 USB 盘

将 nd2cn 项目的所有文件复制到 USB 盘根目录。最终结构应为：

```
USB_ROOT/
├── jci-autoupdate              ← 空文件（触发自动检测）
├── ND2CN.ID                    ← 标识文件
├── $(触发命令).up              ← 触发文件（见下文）
├── install.sh
├── uninstall.sh
├── lib/
│   └── helpers.sh
├── plugins/
│   ├── 00-boot-hook.sh
│   ├── 01-chinese-language.sh
│   ├── ... (其他默认插件)
│   └── optional/
│       ├── 10-touch-unlock.sh
│       ├── 21-track-dashboard.sh
│       └── ... (其他可选插件)
├── app/
│   ├── dashboard.html
│   ├── dashboard-daemon.sh
│   └── dashboard-loader.js
└── resources/
    └── (SSH 公钥、EQ 配置等)
```

### 第三步：创建触发文件

车机的固件更新扫描器会检测 USB 上的 `.up` 文件。nd2cn 利用这个机制触发安装。

**创建 `jci-autoupdate`（空文件）：**
```bash
touch /mnt/usb/jci-autoupdate
```

**创建 `ND2CN.ID`（标识文件）：**
```bash
echo "nd2cn" > /mnt/usb/ND2CN.ID
```

**创建触发用的 `.up` 文件：**

这个文件的**文件名本身**是一段 shell 命令。它在 FAT32 文件系统上需要用特殊方式创建：

```bash
# Linux / macOS 终端执行（USB 挂载在 /mnt/usb）：
touch '/mnt/usb/$(N=0;for i in 1 2 3 4 5 6 7 8 9 10;do cd ..;done;cd tmp;cd mnt;for D in sda1 sdb1 sdc1 sdd1 usb_sda1 usb_sdb1 usb_sdc1 usb_sdd1;do (cd $D&&[ -f ND2CN.ID ]&&sh install.sh)&&N=1&&break;done;[ $N = 1 ]).up'
```

> **重要**：文件名不能包含 `/` 字符（这是所有文件系统的限制），所以用 `cd ..` 逐级回退到根目录再 `cd tmp;cd mnt` 进入目标路径，而不是写 `/tmp/mnt/`。

> **注意**：文件名必须用**单引号**包裹防止本机 shell 展开。这个文件的内容为空——起作用的是文件名。

> **Windows 用户**：Windows 资源管理器无法创建包含 `$()` 的文件名。请使用 WSL (Windows Subsystem for Linux) 或在 Linux 虚拟机中操作。

### 第四步：选择可选插件

如果你需要可选功能，把对应的 `.sh` 文件从 `plugins/optional/` **移动**到 `plugins/` 目录：

```bash
# 例如：启用行车触屏解锁
mv /mnt/usb/plugins/optional/10-touch-unlock.sh /mnt/usb/plugins/

# 例如：启用赛道仪表 App
mv /mnt/usb/plugins/optional/21-track-dashboard.sh /mnt/usb/plugins/
```

**SSH 远程访问**（可选）需要额外步骤：
```bash
# 启用 SSH 插件
mv /mnt/usb/plugins/optional/11-ssh-access.sh /mnt/usb/plugins/

# 把你的 SSH 公钥放到指定目录
mkdir -p /mnt/usb/resources/ssh_keys/
cp ~/.ssh/id_rsa.pub /mnt/usb/resources/ssh_keys/
```

### 第五步：在车上安装

1. **启动发动机**（确保稳定供电，不要用 ACC 模式）
2. **插入 USB 盘**到车机的任一 USB 口
3. 等待约 10-30 秒，车机会自动检测到 USB 上的 `.up` 文件
4. 屏幕弹出**更新确认对话框**——按旋钮确认或点击屏幕上的确认按钮
5. nd2cn 安装脚本开始执行，屏幕显示进度
6. 安装完成后提示重启
7. **拔出 USB 盘**
8. 车机自动重启（如果没有自动重启，手动关闭发动机等待 30 秒后重新启动）

重启后：
- 进入 **设置 → 语言**，选择 **简体中文**
- 界面切换为中文

### 卸载（恢复原始状态）

使用同一张 USB 盘：

```bash
# 删除安装用的 .up 文件，创建卸载用的：
rm '/mnt/usb/$(N=0;for i in 1 2 3 4 5 6 7 8 9 10;do cd ..;done;cd tmp;cd mnt;for D in sda1 sdb1 sdc1 sdd1 usb_sda1 usb_sdb1 usb_sdc1 usb_sdd1;do (cd $D&&[ -f ND2CN.ID ]&&sh install.sh)&&N=1&&break;done;[ $N = 1 ]).up'

touch '/mnt/usb/$(N=0;for i in 1 2 3 4 5 6 7 8 9 10;do cd ..;done;cd tmp;cd mnt;for D in sda1 sdb1 sdc1 sdd1 usb_sda1 usb_sdb1 usb_sdc1 usb_sdd1;do (cd $D&&[ -f ND2CN.ID ]&&sh uninstall.sh)&&N=1&&break;done;[ $N = 1 ]).up'
```

插入车机，等待卸载完成并重启。所有修改将恢复到原厂状态。

## 安装前须知

### 风险说明
- **不会变砖**：所有修改都有原始文件备份，可以通过卸载恢复。最坏情况下，刷一次官方固件即可恢复出厂状态。
- **安装过程中不要断电**：安装脚本会临时将文件系统切换为可写模式，断电可能导致文件不一致。始终保持发动机运行。
- **首次安装可能显示 "NOT finalized" 提示**：这是因为北斗补丁替换了一个正在被系统使用的库文件。重启后一切正常，这不是错误。

### FM 收音机限制
墨西哥版 FM 频率步进为 0.2 MHz（87.7, 87.9, 88.1...），中国使用 0.1 MHz 步进。这是收音机硬件限制，软件无法修改。部分电台频率可能调不到。

### 语音识别和 TTS
NA 固件不包含中文语音识别和 TTS 语音数据。切换到中文后，语音功能将不可用或回退到英文。这不影响 CarPlay/Android Auto 中的语音助手（Siri/Google Assistant）。

### GPS 首次定位
安装后首次开机，GPS 需要重新搜索卫星（星历数据已清除）。在开阔地停车等待约 2-5 分钟即可完成首次定位。此后定位速度将显著提升（北斗+GPS 双系统）。

## 赛道仪表 App 使用说明

启用插件 `21-track-dashboard.sh` 后，在车机的**应用程序**菜单中会出现 **Track Dash** 入口。

### 三种自动视图
- **待机**（车速 < 5 km/h）：水温状态、RPM、档位、计时器
- **公路**（正常行驶）：大字车速、RPM 弧形条、档位
- **赛道**（高 G 力或高 RPM）：G 力圆图 + 车速 + RPM + 油门/刹车 + 转向角

### 旋钮操作
| 操作 | 功能 |
|---|---|
| 旋钮旋转 | 手动切换视图（待机 / 公路 / 赛道） |
| 旋钮上推 | 直接切到赛道视图（手动） |
| 旋钮下推 | 回到自动切换 |
| 旋钮按下 | 计时器 开始 / 暂停 |
| 旋钮快速按两下（0.5 秒内） | 计时器和峰值 G 清零 |
| 旋钮左 / 右推 | 校准面板（仅停车时） |
| 返回键 | 退出仪表 |

右下角状态格：第一行是当前视图，第二行 **自动**（按车速、G 值、转速自动切换）或 **🔒手动**（用旋钮选的，下推旋钮恢复自动）。数据中断时第二行变成琥珀色的"无数据 / 连接中 / 离线"。

### 校准
CAN 信号的缩放因子可能需要在实车上校准。旋钮左/右推（停车时）打开校准面板，显示原始值和转换后的值。可通过 SSH 编辑 `/data/nd2cn/dashboard.conf` 调整参数。

## 技术架构

### 插件系统
- `plugins/` 下的 `.sh` 文件按文件名排序自动执行
- 每个插件定义 `plugin_check`/`plugin_apply`/`plugin_remove`
- 所有修改都是幂等的（重复执行不会出错）
- 备份存储在 `/data/nd2cn/backups/_pristine/`

### 文件写入策略
- **rootfs**（闪存）：仅在安装时写入一次，运行时绝不写入
- **/data/**（闪存）：仅安装时写入一次性配置文件
- **/tmp/**（内存）：所有运行时数据（日志、缓存、仪表遥测）
- **USB**：不写入

### 已知限制
- 油温数据不可用（MX-5 ND 无油温传感器连接到 CAN 总线）
- 水温和环境温度的 D-Bus 信号在 74.00.324A 固件上可能不活跃
- FLAC 无损音频不可用（缺少 GStreamer 解码器包装库）
- 蓝牙仅支持 SBC 编解码（BlueZ 4.98 不支持 AAC/aptX）

## 许可证

本项目参考了以下开源项目的技术方案：
- [TouchTune](https://github.com/Miatafy/TouchTune) (GPL-3.0)
- [OpenCMU](https://github.com/nidr0x/OpenCMU) (MIT)
- [nd-gauges](https://github.com/gabrik/nd-gauges)
- [mzd-custom-app](https://github.com/piotrmocko/mzd-custom-app)
