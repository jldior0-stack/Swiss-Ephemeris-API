#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RUN_DIR="$SCRIPT_DIR/.run"
API_LOG="$RUN_DIR/api.log"
API_PID_FILE="$RUN_DIR/api.pid"

API_HOST="127.0.0.1"
API_PORT="${SWISS_API_PORT:-8765}"
LOCAL_URL="http://$API_HOST:$API_PORT"
PUBLIC_URL="${SWISS_PUBLIC_URL:-https://ephemeris.lumerune.com}"
UVICORN_BIN="$SCRIPT_DIR/.venv/bin/uvicorn"
SCREEN_BIN="$(command -v screen 2>/dev/null || true)"
API_SESSION="swiss-ephemeris-api-$API_PORT"

mkdir -p "$RUN_DIR"

screen_running() {
  local session="$1"
  local sessions
  sessions="$($SCREEN_BIN -ls 2>/dev/null || true)"
  [[ "$sessions" == *".$session"* ]]
}

read_pid() {
  local pid_file="$1"
  [[ -f "$pid_file" ]] || return 1
  tr -dc '0-9' < "$pid_file"
}

managed_process_running() {
  local pid_file="$1"
  local expected="$2"
  local pid command_line

  pid="$(read_pid "$pid_file" 2>/dev/null || true)"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  command_line="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  [[ "$command_line" == *"$expected"* ]]
}

wait_for_api() {
  local attempt
  for attempt in {1..60}; do
    if curl -fsS --max-time 2 "$LOCAL_URL/health" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.25
  done
  return 1
}

ensure_runtime() {
  local uv_bin

  if [[ -z "$SCREEN_BIN" ]]; then
    echo "错误：未找到 screen 命令。" >&2
    return 1
  fi

  if [[ -x "$UVICORN_BIN" ]]; then
    return 0
  fi

  uv_bin="$(command -v uv 2>/dev/null || true)"
  if [[ -z "$uv_bin" ]]; then
    echo "错误：未找到 uv，且项目虚拟环境尚未安装。" >&2
    echo "请先安装 uv：https://docs.astral.sh/uv/" >&2
    return 1
  fi

  echo "首次运行，正在安装 Python 依赖……"
  (cd "$SCRIPT_DIR" && "$uv_bin" sync)
}

start_api() {
  if screen_running "$API_SESSION" || managed_process_running "$API_PID_FILE" "uvicorn app.main:app"; then
    if wait_for_api; then
      echo "API 已在运行：$LOCAL_URL"
      return 0
    fi
    echo "错误：API 会话存在，但健康检查失败；请先执行 ./manage.sh stop。" >&2
    return 1
  fi

  if lsof -nP -iTCP:"$API_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "错误：端口 $API_PORT 已被非托管进程占用。" >&2
    lsof -nP -iTCP:"$API_PORT" -sTCP:LISTEN >&2 || true
    return 1
  fi

  ensure_runtime
  rm -f "$API_PID_FILE"
  : > "$API_LOG"

  "$SCREEN_BIN" -dmS "$API_SESSION" /bin/bash -c \
    'pid_file="$1"; log_file="$2"; work_dir="$3"; shift 3; printf "%s\n" "$$" >"$pid_file"; cd "$work_dir"; exec "$@" >>"$log_file" 2>&1' \
    _ "$API_PID_FILE" "$API_LOG" "$SCRIPT_DIR" \
    env "EPHE_PATH=$SCRIPT_DIR/ephe" \
    "$UVICORN_BIN" app.main:app --host "$API_HOST" --port "$API_PORT"

  if ! wait_for_api; then
    echo "错误：API 启动失败，最近日志如下：" >&2
    tail -n 30 "$API_LOG" >&2 || true
    stop_api >/dev/null 2>&1 || true
    return 1
  fi

  echo "API 已启动：$LOCAL_URL"
}

stop_managed_service() {
  local session="$1"
  local pid_file="$2"
  local expected="$3"
  local display_name="$4"
  local attempt pid was_running=false

  if screen_running "$session"; then
    was_running=true
    "$SCREEN_BIN" -S "$session" -X quit
  fi
  if managed_process_running "$pid_file" "$expected"; then
    was_running=true
    pid="$(read_pid "$pid_file")"
    kill "$pid" 2>/dev/null || true
  fi

  if [[ "$was_running" == false ]]; then
    rm -f "$pid_file"
    echo "$display_name 未运行。"
    return 0
  fi

  for attempt in {1..40}; do
    if ! screen_running "$session" && ! managed_process_running "$pid_file" "$expected"; then
      rm -f "$pid_file"
      echo "$display_name 已停止。"
      return 0
    fi
    sleep 0.25
  done

  pid="$(read_pid "$pid_file" 2>/dev/null || true)"
  if [[ "$pid" =~ ^[0-9]+$ ]] && managed_process_running "$pid_file" "$expected"; then
    echo "$display_name 未能及时退出，正在强制停止。" >&2
    kill -KILL "$pid" 2>/dev/null || true
  fi
  rm -f "$pid_file"
  echo "$display_name 已停止。"
}

stop_api() {
  stop_managed_service "$API_SESSION" "$API_PID_FILE" "uvicorn app.main:app" "API"
}

show_status() {
  if screen_running "$API_SESSION" || managed_process_running "$API_PID_FILE" "uvicorn app.main:app"; then
    if curl -fsS --max-time 2 "$LOCAL_URL/health" >/dev/null 2>&1; then
      echo "API：运行中（健康） $LOCAL_URL"
      echo "公网域名：$PUBLIC_URL"
    else
      echo "API：会话运行中，但健康检查失败"
    fi
  else
    echo "API：未运行"
  fi

}

show_logs() {
  touch "$API_LOG"
  tail -n 100 -f "$API_LOG"
}

show_usage() {
  cat <<'USAGE'
用法：./manage.sh <命令>

命令：
  start        启动 API（公网入口由 Nginx 提供）
  start-local  start 的兼容别名
  stop         停止 API
  restart      重启 API
  status       查看运行状态和配置的公网域名
  url          输出当前 API Base URL
  logs         持续查看 API 日志（Ctrl+C 退出）

可选环境变量：
  SWISS_API_PORT    修改本地端口（默认 8765）
  SWISS_PUBLIC_URL  修改公网域名（默认 https://ephemeris.lumerune.com）
USAGE
}

case "${1:-}" in
  start)
    start_api
    ;;
  start-local)
    start_api
    ;;
  stop)
    stop_api
    ;;
  restart)
    stop_api
    start_api
    ;;
  status)
    show_status
    ;;
  url)
    printf '%s/api/v1\n' "$PUBLIC_URL"
    ;;
  logs)
    show_logs
    ;;
  -h|--help|help|"")
    show_usage
    ;;
  *)
    echo "未知命令：$1" >&2
    show_usage >&2
    exit 2
    ;;
esac
