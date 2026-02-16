#!/usr/bin/env bash
set -euo pipefail

PORT="${1:-3456}"
HOST="${2:-localhost}"

ROOT_DIR="/home/fangyunh/Documents/SimpleSSD_Gem5_simulation"
LOG_DIR="$ROOT_DIR/logs"
PID_FILE="$LOG_DIR/gem5.pid"
LOG_FILE="$LOG_DIR/gem5.out"

if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
  :
else
  echo "Warning: gem5 does not appear to be running."
  echo "Start it with: $ROOT_DIR/script/boot_gem5.sh start"
  if [ -f "$LOG_FILE" ]; then
    echo "Last log: $LOG_FILE"
  fi
fi

if command -v nc >/dev/null 2>&1; then
  exec nc "$HOST" "$PORT"
elif command -v telnet >/dev/null 2>&1; then
  exec telnet "$HOST" "$PORT"
else
  echo "Error: neither nc nor telnet is installed."
  echo "Install one of them and retry." 
  exit 1
fi
