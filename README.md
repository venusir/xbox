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

echo "Xbox 终极安全守护服务已启动..."

while true; do
    STATUS=$(qm status $VM_ID | awk '{print $2}')
    
    # 1. 如果虚拟机正在运行
    if [ "$STATUS" = "running" ]; then
        sleep 5
        continue
    fi

    # 2. 如果检测到虚拟机处于正在关机（shutdown）的状态，强行推进，防止卡死
    if qm status $VM_ID | grep -q "shutdown"; then
        echo "检测到虚拟机正在关机，强制结束残留进程..." >> /var/log/xbox_wake.log
        qm stop $VM_ID
        # 核心防误触：关机后强制睡眠 20 秒，让显卡和 USB 适配器有充足的时间彻底断电和解绑
        echo "进入关机冷却期，暂停监控 20 秒..." >> /var/log/xbox_wake.log
        sleep 20
        continue
    fi

    # 3. 正常的开机探测逻辑（只有在虚拟机彻底 stopped，且过了冷却期才会执行）
    if [ "$STATUS" = "stopped" ]; then
        if lsusb -d 045e:02fe > /dev/null 2>&1; then
            for dev in /sys/bus/usb/devices/*; do
                if [ -e "$dev/idVendor" ] && [ -e "$dev/idProduct" ]; then
                    if [ "$(cat $dev/idVendor)" = "045e" ] && [ "$(cat $dev/idProduct)" = "02fe" ]; then
                        
                        # 向内核发送重置信号
                        echo 0 > "$dev/authorized"
                        sleep 0.5
                        echo 1 > "$dev/authorized"
                        
                        echo "【手柄唤醒】检测到有效信号，正在拉起 Bazzite..." >> /var/log/xbox_wake.log
                        qm start $VM_ID
                        
                        # 开机后强制睡眠 60 秒，防止高频重复触发
                        sleep 60
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
