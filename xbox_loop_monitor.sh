#!/bin/bash

VM_ID="100"
LOG_FILE="/var/log/xbox_wake.log"
VENDOR_ID="045e"
PRODUCT_ID="02fe"

echo "Xbox 变动感应守护服务已启动..."

# 初始化：获取当前适配器的物理路径和设备编号
get_usb_dev_path() {
    for dev in /sys/bus/usb/devices/*; do
        if [ -e "$dev/idVendor" ] && [ -e "$dev/idProduct" ]; then
            if [ "$(cat $dev/idVendor)" = "$VENDOR_ID" ] && [ "$(cat $dev/idProduct)" = "$PRODUCT_ID" ]; then
                echo "$dev"
                return
            fi
        fi
    done
    echo ""
}

# 记录初始的物理设备标识
LAST_DEV_PATH=$(get_usb_dev_path)
if [ -n "$LAST_DEV_PATH" ] && [ -e "$LAST_DEV_PATH/devnum" ]; then
    LAST_DEV_NUM=$(cat "$LAST_DEV_PATH/devnum")
else
    LAST_DEV_NUM=""
fi

while true; do
    CURRENT_STATUS=$(qm status $VM_ID | awk '{print $2}')
    
    # 1. 虚拟机只要开着，脚本彻底冬眠，不读取任何硬件状态
    if [ "$CURRENT_STATUS" = "running" ]; then
        sleep 5
        # 持续更新关闭前的状态，确保关机瞬间数据是最新的
        LAST_DEV_PATH=$(get_usb_dev_path)
        if [ -n "$LAST_DEV_PATH" ] && [ -e "$LAST_DEV_PATH/devnum" ]; then
            LAST_DEV_NUM=$(cat "$LAST_DEV_PATH/devnum")
        fi
        continue
    fi

    # 2. 只有在虚拟机彻底 stopped 状态下，才处理逻辑
    if [ "$CURRENT_STATUS" = "stopped" ]; then
        
        # 获取当前的物理路径和设备编号
        CONFIRM_PATH=$(get_usb_dev_path)
        
        if [ -n "$CONFIRM_PATH" ] && [ -e "$CONFIRM_PATH/devnum" ]; then
            CURRENT_DEV_NUM=$(cat "$CONFIRM_PATH/devnum")
            
            # 【核心安全锁】
            # 如果当前的设备编号和虚拟机刚关闭、或者上一次闲置时的编号完全一致
            # 说明手柄根本没按，只是关机后残留的静态硬件，绝对不触发开机！
            if [ "$CURRENT_DEV_NUM" = "$LAST_DEV_NUM" ]; then
                sleep 2
                continue
            fi
            
            # 如果设备编号发生了改变，说明手柄按下了大西瓜键，激活了全新的物理握手信号
            echo "$(date): 【手柄唤醒】检测到合法的无线唤醒电信号 (DevNum: $LAST_DEV_NUM -> $CURRENT_DEV_NUM)，拉起 Bazzite..." >> $LOG_FILE
            
            # 强制冲刷授权确保握手
            echo 0 > "$CONFIRM_PATH/authorized"
            sleep 0.5
            echo 1 > "$CONFIRM_PATH/authorized"
            
            # 唤醒虚拟机
            qm start $VM_ID
            
            # 更新标记，并强制进入 45 秒完全冰封期
            LAST_DEV_NUM=$CURRENT_DEV_NUM
            sleep 45
        else
            # 如果连适配器都没插，清空标记
            LAST_DEV_NUM=""
        fi
    fi

    sleep 2
done
