# PVE + Flirc 遥控器启动虚拟机完整方案

## 📌 前言
本文档详细记录如何在 Proxmox VE (PVE) 宿主机上，利用 **Flirc USB 红外接收器** 和电视遥控器，实现一键启动指定虚拟机（如 Bazzite 游戏系统）。  
方案包含按键映射、`evsieve` 事件监听、防重复启动脚本及 systemd 服务配置，最终实现按下遥控器按钮 → 自动启动虚拟机的流畅体验。

---

## 🧰 准备工作

### 硬件
- **Flirc USB 接收器**（[官网](https://flirc.tv/)）
- **任意红外遥控器**（电视、机顶盒等）
- **一台安装 Proxmox VE 的宿主机**（本文以 PVE 9.0 为例）

### 软件环境
- PVE 宿主机可联网（用于安装依赖）
- 一台 Windows 电脑（用于 Flirc 按键映射，也可在 Linux 下用命令行完成，但推荐 GUI）

---

## 🔧 步骤一：在 Windows 上映射 Flirc 按键

虽然 Flirc 配置存储在设备内部，可在任意系统使用，但 Windows GUI 工具最直观。

1. 下载 Flirc GUI 软件：  
   [https://flirc.tv/software](https://flirc.tv/software)

2. 安装并运行，插入 Flirc 设备。

3. 点击 **`Controllers`** → 选择 **`Full Keyboard`**（全键盘模式）。

4. 在虚拟键盘上点击一个你想“改造”的按键（例如 `F12`）。

5. 软件提示“请按下遥控器按钮”时，按下你的遥控器上的某个按键（如红色电源键或 Favorites 键）。

6. 显示“Recorded Successfully”即完成映射。  
   **建议**：记录下该按键的用途，比如“开机键”。

7. 可选：点击 **`File`** → **`Save Configuration`** 备份配置。

完成后，拔下 Flirc 插入 PVE 宿主机即可。

---

## 🐧 步骤二：在 PVE 宿主机上安装 `evsieve`

`evsieve` 是一个强大的输入事件过滤工具，用于捕获遥控器按键并执行命令。

### 2.1 安装依赖
```bash
apt update
apt install -y build-essential git libevdev-dev libudev-dev pkg-config cargo
```

### 2.2 从源码编译 `evsieve`
```bash
cd /tmp
git clone https://github.com/KarsMulder/evsieve.git
cd evsieve
cargo build --release
sudo install -m 755 -t /usr/local/bin target/release/evsieve
```

### 2.3 验证安装
```bash
evsieve --version
```
应输出类似 `evsieve 1.4.0`。

### 2.4 加载 `uinput` 内核模块（必需）
```bash
modprobe uinput
echo uinput > /etc/modules-load.d/uinput.conf
```

---

## 🔍 步骤三：查找 Flirc 设备路径与按键名

### 3.1 确认 Flirc 被识别
```bash
lsusb | grep -i flirc
```
应看到类似 `Bus 001 Device 006: ID 20a0:0001 Flirc, Inc. Flirc` 的输出。

### 3.2 查找设备事件路径
```bash
ls /dev/input/by-id/*-event-kbd
```
输出示例：  
`/dev/input/by-id/usb-flirc.tv_flirc-if0-event-kbd`  
记下该路径，后续脚本中需要使用。

### 3.3 安装 `evtest` 工具
```bash
apt install -y evtest
```

### 3.4 捕获按键对应的键名
```bash
evtest /dev/input/by-id/你找到的设备路径
```
按下遥控器上映射好的按钮，终端会输出：
```
Event: time ... type 1 (EV_KEY), code 230 (KEY_F12), value 1
```
记录 `KEY_` 开头的键名，例如 `KEY_F12` 或 `KEY_FAVORITES`。

按 `Ctrl+C` 退出 `evtest`。

---

## 📜 步骤四：编写启动脚本（带防重复启动）

创建脚本文件 `/usr/local/bin/flirc-start-bazzite.sh`：

```bash
#!/bin/bash

# ================================================
# 通过 Flirc + evsieve 启动指定 PVE 虚拟机
# 含状态检查，避免重复启动
# ================================================

# ----- 用户配置区（请修改为实际值）-----
FLIRC_DEV="/dev/input/by-id/usb-flirc.tv_flirc-if0-event-kbd"   # 步骤三中获取的设备路径
TRIGGER_KEY="KEY_F12"                                           # 步骤三中获取的键名
VM_ID="101"                                                     # 你的 Bazzite 虚拟机 ID
LOG_FILE="/var/log/flirc-bazzite.log"                           # 日志文件路径
# ------------------------------------------

# 确保日志目录存在
mkdir -p "$(dirname "$LOG_FILE")"

# 带时间戳的日志函数
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

log "Flirc 监听服务启动 (设备: $FLIRC_DEV, 触发键: $TRIGGER_KEY)"

# 启动 evsieve，捕获按键并执行启动逻辑
exec /usr/local/bin/evsieve --input "$FLIRC_DEV" grab \
    --hook "ev:$TRIGGER_KEY" \
    --output exec:"/bin/bash -c '
        VM_ID=$VM_ID
        LOG_FILE=$LOG_FILE
        log() { echo \"\$(date \"+%Y-%m-%d %H:%M:%S\") - \$1\" >> \"\$LOG_FILE\"; }

        # 检查虚拟机状态
        STATUS=\$(/usr/sbin/qm status \$VM_ID 2>/dev/null | awk \"{print \\\$2}\")
        if [ \"\$STATUS\" = \"running\" ]; then
            log \"收到启动信号，但虚拟机 \$VM_ID 已在运行中，忽略启动请求。\"
        else
            log \"收到启动信号，正在启动虚拟机 \$VM_ID ...\"
            /usr/sbin/qm start \$VM_ID
            if [ \$? -eq 0 ]; then
                log \"虚拟机 \$VM_ID 启动命令已成功发送。\"
            else
                log \"虚拟机 \$VM_ID 启动失败，请检查 PVE 日志。\"
            fi
        fi
    '"
```

赋予执行权限：
```bash
chmod +x /usr/local/bin/flirc-start-bazzite.sh
```

---

## ⚙️ 步骤五：创建 systemd 服务（开机自启）

### 5.1 创建服务文件
```bash
nano /etc/systemd/system/flirc-bazzite.service
```

粘贴以下内容：
```ini
[Unit]
Description=Flirc Service to Start Bazzite VM
After=multi-user.target

[Service]
Type=simple
ExecStart=/usr/local/bin/flirc-start-bazzite.sh
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
```

### 5.2 启用并启动服务
```bash
systemctl daemon-reload
systemctl enable flirc-bazzite.service
systemctl start flirc-bazzite.service
```

### 5.3 检查服务状态
```bash
systemctl status flirc-bazzite.service
```
应显示 `active (running)`。

---

## 🧪 步骤六：测试与验证

### 6.1 手动运行脚本（前台测试）
停止 systemd 服务：
```bash
systemctl stop flirc-bazzite.service
```

手动执行：
```bash
/usr/local/bin/flirc-start-bazzite.sh
```
此时代理在前台运行，按下遥控器按钮，观察：
- 虚拟机是否启动（可用 `qm status <VM_ID>` 查看）
- 日志文件 `/var/log/flirc-bazzite.log` 是否产生记录

按 `Ctrl+C` 终止前台进程。

### 6.2 测试防重复逻辑
1. 确保虚拟机已运行。
2. 按下遥控器按钮。
3. 查看日志，应出现“已在运行中，忽略启动请求”。

### 6.3 测试后台服务
```bash
systemctl start flirc-bazzite.service
qm stop <VM_ID>               # 确保虚拟机为关闭状态
# 按下遥控器按钮
qm status <VM_ID>             # 应变为 running
```

### 6.4 测试开机自启（可选）
重启 PVE 宿主机，不登录，直接按遥控器按钮，验证虚拟机被启动。

---

## 🐛 常见问题排查

| 问题现象 | 可能原因 | 解决方法 |
|---------|----------|----------|
| `evsieve: command not found` | 未正确安装或 PATH 不含 `/usr/local/bin` | 使用 `which evsieve` 确认路径，脚本中使用绝对路径 |
| `--hook` 参数报错 `Invalid argument` | 缺少 `ev:` 前缀 | 写成 `--hook "ev:KEY_F12"` |
| 按下按键无反应，Flirc 蓝灯不亮 | 遥控器电池没电或未配对 | 重新在 Windows GUI 中学习按键 |
| 日志显示启动命令成功但虚拟机未启动 | `qm` 命令路径错误 | 脚本中使用 `/usr/sbin/qm` |
| 服务启动后立即退出（exit-code） | 设备路径错误或权限不足 | 检查 `FLIRC_DEV` 是否正确；运行 `evtest` 测试读取权限 |
| `/dev/uinput` 不存在 | 未加载内核模块 | `modprobe uinput` 并写入 `/etc/modules-load.d/` |
| 按键有时灵有时不灵 | 红外信号遮挡 | 将 Flirc 接收器置于开阔位置 |

---

## 📚 附录：常用维护命令

```bash
# 查看服务状态
systemctl status flirc-bazzite.service

# 重启服务
systemctl restart flirc-bazzite.service

# 实时查看服务日志
journalctl -u flirc-bazzite.service -f

# 查看启动日志
tail -f /var/log/flirc-bazzite.log

# 停止服务
systemctl stop flirc-bazzite.service

# 临时禁用开机自启
systemctl disable flirc-bazzite.service
```

---

## 🎉 总结

恭喜！现在你可以像使用电视机一样，用遥控器一键启动 PVE 中的虚拟机了。该方案不仅适用于 Bazzite，也可用于任何你需要远程启动的虚拟机（如 Windows、LibreELEC 等）。  
Flirc + `evsieve` 的组合为 PVE 主机提供了一个**低成本、低延迟、无需网络**的硬件唤醒通道，完美融入家庭影音环境。

*文档结束*
