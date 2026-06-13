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
