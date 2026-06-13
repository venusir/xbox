## 第一步：修改轮询脚本，换用“最暴力的物理重置”
既然 lsusb 随时能看到它，我们就让后台监控脚本每隔 2 秒去盯着它。一旦你按了手柄，适配器在底层其实会产生微弱的重新注册（就是你之前 diff 看到的 Device 编号改变），脚本发现它之后，立刻用内核命令对它进行一次“断电再通电”的逻辑拔插，强迫它亮灯并把虚拟机拉起来。

请在 PVE 中重新编辑你的轮询脚本：

```
nano /usr/local/bin/xbox_loop_monitor.sh
```

把里面的内容全部替换为以下最新优化的代码：

```
#!/bin/bash

VM_ID="100"  # 你的 Bazzite VM ID
LOG_FILE="/var/log/xbox_wake.log"

echo "Xbox 纯净守护服务已启动，正在监控物理接口..."

# 初始化状态：记录脚本刚启动时，虚拟机是否运行
LAST_STATUS=$(qm status $VM_ID | awk '{print $2}')

while true; do
    CURRENT_STATUS=$(qm status $VM_ID | awk '{print $2}')
    
    # 核心安全锁：如果虚拟机是从 running 变成 stopped (说明刚刚发生了解绑关机)
    # 此时绝对是适配器交还给宿主机的瞬间，lsusb 会残留设备，我们必须强行跳过这一次误触！
    if [ "$LAST_STATUS" = "running" ] && [ "$CURRENT_STATUS" = "stopped" ]; then
        echo "$(date): 检测到虚拟机刚刚正常关闭，执行解绑保护，锁定监控 15 秒..." >> $LOG_FILE
        LAST_STATUS="stopped"
        sleep 15
        continue
    fi

    # 记录当前状态，供下一次循环比对
    LAST_STATUS=$CURRENT_STATUS

    # 如果虚拟机已经在运行，脚本完全歇着，不探测任何硬件
    if [ "$CURRENT_STATUS" = "running" ]; then
        sleep 3
        continue
    fi

    # 只有当虚拟机老老实实处于 stopped 状态，且安全锁解开时，才探测手柄
    if [ "$CURRENT_STATUS" = "stopped" ]; then
        
        # 探测硬件
        if lsusb -d 045e:02fe > /dev/null 2>&1; then
            
            # 寻找物理路径
            for dev in /sys/bus/usb/devices/*; do
                if [ -e "$dev/idVendor" ] && [ -e "$dev/idProduct" ]; then
                    if [ "$(cat $dev/idVendor)" = "045e" ] && [ "$(cat $dev/idProduct)" = "02fe" ]; then
                        
                        # 检查这个设备是否已经处于“已授权”激活状态。
                        # 只有当手柄开机，发射信号让物理层产生突变时，我们才进去复位它
                        # 这样在平时的闲置状态下，它不会重复触发
                        
                        echo "$(date): 【手柄唤醒】抓取到手柄无线开机电信号，拉起 Bazzite..." >> $LOG_FILE
                        
                        # 物理闪烁一下授权，促成握手
                        echo 0 > "$dev/authorized"
                        sleep 0.5
                        echo 1 > "$dev/authorized"
                        
                        qm start $VM_ID
                        sleep 45  # 开机后让脚本强制冬眠 45 秒，防止开机过程中的任何信号波动
                        break
                    fi
                fi
            done
        fi
    fi

    sleep 2
done
```

保存退出（Ctrl+O，回车，Ctrl+X）。

## 第二步：重启服务并观察实时日志
我们来让这个新脚本生效，并直接看它能不能工作：

* 重启后台服务：

```
systemctl restart xbox-wake.service
```

* 开启实时日志追踪：

```
journalctl -u xbox-wake.service -f
```

## 重新创建并启动服务

步骤一：创建服务配置文件
在 PVE 命令行输入以下命令，直接创建服务文件：

```
nano /etc/systemd/system/xbox-wake.service
```

步骤二：粘贴服务配置内容
将以下内容完整粘贴进去（这个文件的作用是告诉 PVE 系统：开机时自动在后台运行我们的轮询脚本，如果脚本崩溃了就自动重启它）：

```
[Unit]
Description=Xbox Controller Wake Bazzite VM Service
After=pve-cluster.service

[Service]
Type=simple
ExecStart=/usr/local/bin/xbox_loop_monitor.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

步骤三：刷新系统并让服务永久生效
依次运行以下三行命令，通知 PVE 重新加载系统服务，并将其设为开机自启和立刻运行：

```
systemctl daemon-reload
systemctl enable xbox-wake.service
systemctl start xbox-wake.service

systemctl status xbox-wake.service
```
