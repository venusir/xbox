# PVE + Flirc + triggerhappy 实现遥控器启动虚拟机完整方案

## 1. 方案概述

利用 **Flirc USB 红外接收器** 将电视遥控器信号转换为键盘按键（`KEY_F12`），配合 **triggerhappy** 在 PVE 宿主机上监听该按键，并通过 **Proxmox VE API Token** 调用 `pvesh` 或 `curl` 启动指定的虚拟机（例如 Bazzite）。  
该方案无需网络唤醒，完全本地化，响应迅速，适合客厅 HTPC 或游戏主机场景。

---

## 2. 所需硬件与软件

- **硬件**：
  - Proxmox VE 宿主机一台
  - Flirc USB 接收器（[官网](https://flirc.tv/)）
  - 任意红外遥控器（电视、机顶盒等）
- **软件**：
  - Proxmox VE 8.x / 9.x
  - Windows PC（用于 Flirc 按键映射，可选）
  - PVE 宿主机已安装 `triggerhappy`

---

## 3. 步骤一：在 Windows 上映射 Flirc 按键

Flirc 的配置存储在设备内部，可在 Windows 上用 GUI 完成，然后直接插到 PVE 宿主使用。

1. 下载并安装 Flirc GUI：  
   [https://flirc.tv/software](https://flirc.tv/software)

2. 插入 Flirc，打开软件，选择 **`Controllers`** → **`Full Keyboard`**（全键盘模式）。

3. 在虚拟键盘上点击你希望作为“开机键”的按键（例如 `F12`）。

4. 按下遥控器上的某个按钮（建议选一个不常用的按键，如红色电源键或 Favorites 键）。

5. 提示 “Recorded Successfully” 即完成。  
   **记录**：该遥控器按钮对应键盘 `F12`。

6. 可选：点击 `File` → `Save Configuration` 备份配置。

7. 拔出 Flirc，插入 PVE 宿主机。

---

## 4. 步骤二：在 PVE 宿主机上安装与配置

### 4.1 安装 triggerhappy

```bash
apt update
apt install -y triggerhappy
```

### 4.2 验证 Flirc 设备及按键

查找 Flirc 对应的输入事件设备（通常为 `/dev/input/eventX`），并确认按键键名。

```bash
# 查看 Flirc 设备路径
ls /dev/input/by-id/*flirc*

# 使用 evtest 监听按键（替换为实际路径）
evtest /dev/input/by-id/usb-flirc.tv_flirc_xxx-if01-event-kbd
```

按下遥控器上的开机键，输出应类似：
```
Event: time ... type 1 (EV_KEY), code 88 (KEY_F12), value 1
```
记录下按键名 `KEY_F12`。

按 `Ctrl+C` 退出 `evtest`。

---

## 5. 步骤三：创建 Proxmox VE API Token

为了在非交互环境下（triggerhappy 服务）安全启动虚拟机，使用 API Token 认证。

### 5.1 在 PVE Web 界面创建 Token

1. 登录 Proxmox VE Web 管理界面。
2. 点击 **`Datacenter`** → **`Permissions`** → **`API Tokens`**。
3. 点击 **`Add`**：
   - **User**: `root@pam`
   - **Token ID**: 例如 `triggerhappy`
   - **Privilege Separation**: 不勾选（继承 root 权限，最简单）
4. 点击 **`Add`**，弹出窗口显示 **`Secret`**（Token 密钥）。  
   **务必保存此密钥**，关闭后无法再查看。  
   示例 Token ID: `root@pam!triggerhappy`  
   示例 Secret: `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`

### 5.2 编写启动脚本（使用 API Token）

创建 `/usr/local/bin/start-bazzite-vm.sh`：

```bash
nano /usr/local/bin/start-bazzite-vm.sh
```

粘贴以下内容（替换 `VM_ID`、`TOKEN_ID`、`SECRET` 为实际值）：

```bash
#!/bin/bash

VM_ID="100"                      # 你的 Bazzite 虚拟机 ID
PVE_HOST="localhost"             # PVE 主机地址
NODE_NAME="localhost"            # 节点名称（localhost 自动识别）
TOKEN_ID="root@pam!triggerhappy" # API Token ID
SECRET="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" # 你的 Secret

# 日志文件（调试用）
LOG_FILE="/tmp/bazzite-api.log"

echo "$(date): Script executed." >> $LOG_FILE

# 调用 Proxmox API 启动虚拟机
response=$(curl --silent --insecure -X POST \
  -H "Authorization: PVEAPIToken=$TOKEN_ID=$SECRET" \
  "https://$PVE_HOST:8006/api2/json/nodes/$NODE_NAME/qemu/$VM_ID/status/start")

echo "$(date): API response - $response" >> $LOG_FILE

if echo "$response" | grep -q '"data":null'; then
    echo "$(date): VM $VM_ID started successfully." >> $LOG_FILE
else
    echo "$(date): Failed to start VM $VM_ID." >> $LOG_FILE
fi
```

赋予执行权限：

```bash
chmod +x /usr/local/bin/start-bazzite-vm.sh
```

### 5.3 测试脚本手动执行

先关闭虚拟机，然后手动运行脚本：

```bash
qm stop 100
/usr/local/bin/start-bazzite-vm.sh
qm status 100
```

若显示 `running` 且日志无报错，则脚本正常。

---

## 6. 步骤四：配置 triggerhappy 规则

创建规则文件，监听 `KEY_F12` 并执行上述脚本。

```bash
echo "KEY_F12 1 /usr/local/bin/start-bazzite-vm.sh" > /etc/triggerhappy/triggers.d/bazzite-start.conf
```

重启 triggerhappy 服务：

```bash
systemctl restart triggerhappy
systemctl enable triggerhappy   # 设置开机自启
```

---

## 7. 步骤五：最终测试

1. 确保虚拟机处于关闭状态：`qm stop 100`
2. 按下遥控器上已映射的按键（对应 `F12`）。
3. 等待 2-3 秒，检查虚拟机状态：
   ```bash
   qm status 100
   ```
   应输出 `status: running`。

4. 查看 triggerhappy 日志和 API 日志：
   ```bash
   journalctl -u triggerhappy -f
   cat /tmp/bazzite-api.log
   ```

若虚拟机成功启动，则大功告成。

---

## 8. 故障排查

| 现象 | 可能原因 | 解决方法 |
|------|----------|----------|
| 按下遥控器无反应 | Flirc 未识别或按键未映射 | 重新插拔 Flirc；在 Windows 上重新映射按键 |
| `evtest` 能捕获但 triggerhappy 无动作 | triggerhappy 服务未运行或规则未生效 | `systemctl status triggerhappy`；检查 `/etc/triggerhappy/triggers.d/` 目录 |
| API 返回 `401 Unauthorized` | Token ID 或 Secret 错误 | 重新创建 Token，核对脚本中的值 |
| API 返回 `Parameter verification failed` | curl 命令中包含了多余的 `-d "{}"` | 确保启动 VM 的 POST 请求不含请求体（见上述脚本） |
| 手动运行脚本成功，遥控器触发失败 | triggerhappy 执行环境缺少 PATH 或权限 | 脚本中已使用绝对路径，且无需额外环境；若仍失败，检查 `journalctl -u triggerhappy` 中的错误 |
| 虚拟机启动时出现 PCI reset 警告 | 直通设备时正常现象 | 忽略，不影响启动 |

---

## 9. 附加说明

- **防重复启动**：当前脚本每次调用 API 都会发送启动命令，即使虚拟机已运行，API 会返回错误但不会影响。如需严格防重复，可在脚本开头先用 `qm status` 检查状态，但需注意 `qm` 命令在 triggerhappy 环境中可能因缺少认证而失败。推荐保持简单。
- **关机的实现**：可将另一个遥控器按键映射为 `KEY_F11`，创建新规则执行 `qm stop 100` 的类似脚本。
- **安全建议**：若担心 Token 泄露，可限制其权限（创建专用用户并分配 `PVEVMAdmin` 角色），并在脚本中妥善保管 Token 文件。

---

## 10. 总结

通过 Flirc + triggerhappy + Proxmox API Token，你成功实现了用电视遥控器一键启动 PVE 虚拟机。该方案稳定、快速、无需网络依赖，完美融入家庭影音环境。

---

*文档创建日期：2026-06-14*  
*适用于 Proxmox VE 8+ / 9+*
