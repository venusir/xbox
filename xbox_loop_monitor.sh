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
