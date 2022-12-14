#!/bin/bash
# STEMMechanics Minecraft service script, running throught tmux
# Based off https://github.com/moonlight200/minecraft-tmux-service
# updated to support the start/restarts scripts from 
# https://gist.github.com/Prof-Bloodstone/6367eb4016eaf9d1646a88772cdbbac5

# Minecraft Start Command flags require Oracle Graalvm Java Enterprise
# https://www.oracle.com/downloads/graalvm-downloads.html

MC_HOME="/var/minecraft"
MC_PID_FILE="$MC_HOME/minecraft-server.pid"
MC_START_CMD="./start.sh"
MC_STOP_FILE="$MC_HOME/stop.tmp"
SERVER_NAME=froels
BACKUP_DIR="/var/minecraft/backups"

TMUX_SOCKET="/tmp/minecraft"
TMUX_SESSION="minecraft"

B2_ACC_ID=
B2_APP_KEY=
B2_BUCKET_NAME=

DELETE_LOGS_OLDER_THAN=60
KEEP_ALL_BACKUPS_BEFORE=28
KEEP_WEEKLY_BACKUPS_BEFORE=84

TODAY_DATE="$(date +'%Y-%m-%d')"
TODAY_DATE_TIME="$(date +'%Y-%m-%d_%H-%M-%S')"

is_server_running() {
    tmux -S $TMUX_SOCKET has -t $TMUX_SESSION > /dev/null 2>&1
    return $?
}

mc_command() {
    cmd="$1"
    tmux -S $TMUX_SOCKET send-keys -t $TMUX_SESSION.0 "$cmd" ENTER
    return $?
}

test_user() {
    if [ -e /tmp/minecraft ] && [ ! -O $TMUX_SOCKET ]; then
        user="$(ls -ld /tmp/minecraft | awk '{print $3}')"
        echo "This script is required to be run under the account '$user' to match the tmux session"
        return 1
    fi

    return $?
}

start_server() {
    if is_server_running; then
        echo "Server already running"
        return 1
    fi

    test_user
    if [ $? -ne 0 ]; then
        return 1
    fi

    echo "Starting minecraft server in tmux session"
    tmux -S $TMUX_SOCKET new -c $MC_HOME -s $TMUX_SESSION -d "$MC_START_CMD"
    chmod g+rw $TMUX_SOCKET

    pid=$(tmux -S $TMUX_SOCKET list-sessions -F '#{pane_pid}')
    if [ "$(echo $pid | wc -l)" -ne 1 ]; then
        echo "Could not determine PID, multiple active sessions"
        return 1
    fi
    echo -n "$pid" > "$MC_PID_FILE"

    return $?
}

stop_server() {
    if ! is_server_running; then
        echo "Server is not running!"
        return 1
    fi

    test_user
    if [ $? -ne 0 ]; then
        return 1
    fi

    # Warn players
    echo "Warning players"

    delay=$1
	if [ -z "$delay" ]
	then
		delay=30
	fi

	reason=$2
    if [ -z "$reason" ]
    then
        reason=Shutdown
    fi

    while [ "$delay" -gt 60 ]
    do
		echo "$reason in $((delay/60)) minutes"
        mc_command "tellraw @a {\"text\":\"[SERVER] $reason in $((delay/60)) minutes\",\"color\":\"gold\"}"
        sleep 60
        delay=$((delay-60))
    done

    while [ "$delay" -gt 0 ]
    do
		echo "$reason in $delay seconds"
        mc_command "tellraw @a {\"text\":\"[SERVER] $reason in $delay seconds\",\"color\":\"gold\"}"
        sleep 10
        delay=$((delay-10))
    done

    # Create stop file
    # echo "1" > $MC_STOP_FILE

    # Issue shutdown
    echo "Kicking players"
    mc_command "kickall"
    echo "Stopping server"
    mc_command "stop"
    if [ $? -ne 0 ]; then
        echo "Failed to send stop command to server"
        return 1
    fi

    # Wait for server to stop
    wait=0
    while is_server_running; do
        sleep 1

        wait=$((wait+1))
        if [ $wait -gt 60 ]; then
            echo "Could not stop server, timeout"
            return 1
        fi
    done

    rm -f "$MC_PID_FILE"

    return 0
}

reload_server() {
    tmux -S $TMUX_SOCKET send-keys -t $TMUX_SESSION.0 "reload" ENTER
    return $?
}

attach_session() {
    if ! is_server_running; then
        echo "Cannot attach to server session, server not running"
        return 1
    fi

    tmux -S $TMUX_SOCKET attach -t $TMUX_SESSION
    return 0
}

backup() {
    if [ -n "$B2_ACC_ID" ]
    then
        if is_server_running; then
            mc_command "tellraw @a {\"text\":\"[SERVER] Backup started...\",\"color\":\"gold\"}"
            mc_command "save-off"
        fi

        mkdir -p ${BACKUP_DIR}
        chmod 777 ${BACKUP_DIR}

        echo "Zipping server files"

        cd ${MC_HOME} || exit
        zip -q -r "${BACKUP_DIR}/${TODAY_DATE_TIME}_${SERVER_NAME}.zip" . -x ./backups**\* ./cache**\* ./config**\* ./crash-reports**\* ./libraries**\* ./logs**\* ./versions/**\*

        if is_server_running; then
            mc_command "save-on"
            mc_command "save-all"
            mc_command "tellraw @a {\"text\":\"[SERVER] Storing backups...\",\"color\":\"gold\"}"
        fi

        /usr/local/bin/b2 authorize-account "$B2_ACC_ID" "$B2_APP_KEY" >/dev/null

        cd "${BACKUP_DIR}" || exit

        for f in *; do
            echo "Uploading $f to B2"
            /usr/local/bin/b2 upload_file --noProgress "$B2_BUCKET_NAME" "$BACKUP_DIR/$f" "$f" >/dev/null
            rm -f "$BACKUP_DIR/$f"
        done

        if is_server_running; then
            mc_command "tellraw @a {\"text\":\"[SERVER] Backup complete\",\"color\":\"gold\"}"
        fi

        echo "Backup complete"
        return 0
    fi

    echo "B2 account not set"

    return 1
}

clean() {
    # minecraft logs
    cd ${MC_HOME}/logs || exit
    for LOG_FILE in *
    do
        # delete minecraft logs older than 60 days
        if [[ $LOG_FILE =~ ([0-9]{4}-[0-9]{2}-[0-9]{2}).*\.log\.gz$ ]]; then
            LOG_DATE=${BASH_REMATCH[1]}
            DAYS_BEFORE=$(( (`date --date="00:00" +%s` - `date -d "$LOG_DATE" +%s`) / (24*3600) ))
            if [ $DAYS_BEFORE -gt $DELETE_LOGS_OLDER_THAN ]; then
                echo "Deleting older log '$LOG_FILE'"
                rm -f "$LOG_FILE"
            fi
        # compress chat logs that are not today
        elif [[ $LOG_FILE =~ ([0-9]{4}-[0-9]{2}-[0-9]{2})(.*\.log)$ ]]; then
            if [ $TODAY_DATE != ${BASH_REMATCH[1]} ]; then
                if [ ! -f "$LOG_FILE.gz" ]; then
                    gzip $LOG_FILE
                fi
            fi
        fi

    done

    # older backups on Backblaze
    /usr/local/bin/b2 authorize-account "$B2_ACC_ID" "$B2_APP_KEY" >/dev/null

    for ROW in $(/usr/local/bin/b2 ls "$B2_BUCKET_NAME" --json | jq -r '.[] | @base64')
    do
        _jq() {
            echo ${ROW} | base64 --decode | jq -r ${1}
        }

        FILE_ID=$(_jq '.fileId')
        FILE_NAME=$(_jq '.fileName')

        DELETE=0
        if [[ $FILE_NAME =~ ([0-9]{4}-[0-9]{2}-[0-9]{2})_[a-z0-9.-_]*\.(zip|gz)$ ]]; then
            FILE_DATE=${BASH_REMATCH[1]}
            DAYS_BEFORE=$(( (`date +%s` - `date -d "$FILE_DATE" +%s`) / (24*3600) ))
            if [ $DAYS_BEFORE -gt $KEEP_ALL_BACKUPS_BEFORE ]; then
                DAY_OF_MONTH=`date --date=${BASH_REMATCH[1]} +%d`
                if [ $DAYS_BEFORE -lt $KEEP_WEEKLY_BACKUPS_BEFORE ]; then
                    # if day is NOT a Sunday
                    if [ `date --date=${BASH_REMATCH[1]} +%u` -ne 7 ]; then
                        DELETE=1
                    fi
                else
                    # if day is NOT first Sunday of month
                    if [ `cal $(date --date=${BASH_REMATCH[1]} +%m)  $(date --date=${BASH_REMATCH[1]} +%Y) | awk 'NF==7 && !/^Su/{print $1;exit}'` -ne $DAY_OF_MONTH ]; then
                        DELETE=1
                    fi
                fi
            fi
        fi

        if [ $DELETE -eq 1 ]; then
            echo "Deleting older backup '$FILE_NAME'"
            /usr/local/bin/b2 delete-file-version "$FILE_NAME" "$FILE_ID">/dev/null
        fi
    done

    return 0
}

case "$1" in
start)
    start_server
    exit $?
    ;;
stop)
    stop_server 600
    exit $?
    ;;
stop-now)
    stop_server 30
    exit $?
    ;;
restart)
    stop_server 600 "Restart"
    start_server
    exit $?
    ;;
restart-now)
    stop_server 30 "Restart"
    start_server
    exit $?
    ;;
reload)
    reload_server
    exit $?
    ;;
attach)
    attach_session
    exit $?
    ;;
backup)
    backup
    exit $?
    ;;
clean)
    clean
    exit $?
    ;;
*)
    echo "Usage: ${0} {start|stop|stop-now|restart|restart-now|reload|attach|backup|clean}"
    exit 2
    ;;
esac
