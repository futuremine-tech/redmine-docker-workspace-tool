#!/usr/bin/env bash
# lib/rdc/logger.bash
# 標準出力とワークスペース直下の redmine-docker-workspace.log の二重出力を担う Domain モジュール
# RDC_LOG_FILE は各 Service が workspace 解決後に export して設定する
# 根拠要件: RDC-REQ-F0601

_logger_write() {
  local level="$1"
  local msg="$2"
  local line="[${level}] ${msg}"
  echo "$line"
  if [[ -n "${RDC_LOG_FILE:-}" ]]; then
    mkdir -p "$(dirname "${RDC_LOG_FILE}")" 2>/dev/null || true
    echo "$line" >> "${RDC_LOG_FILE}" 2>/dev/null || true
  fi
}

# logger_info()
# INFO レベルのメッセージを出力する
# args: message
logger_info() {
  local msg="${1:?message required}"
  _logger_write "INFO" "$msg"
}

# logger_error()
# ERROR レベルのメッセージを出力する
# args: message
logger_error() {
  local msg="${1:?message required}"
  _logger_write "ERROR" "$msg" >&2
}

# logger_debug()
# DEBUG レベルのメッセージを出力する（-v / --verbose 時のみ）
# args: message
logger_debug() {
  local msg="${1:?message required}"
  if [[ "${RDC_VERBOSE:-}" == "true" || "${RDC_VERBOSE:-}" == "1" ]]; then
    _logger_write "DEBUG" "$msg"
  fi
}

# logger_show_spinner()
# 指定 PID の完了までスピナーを表示する（TTY のみ; 非 TTY では何もしない）
# args: pid, message
logger_show_spinner() {
  local pid="${1:?pid required}"
  local message="${2:-Working}"

  if [[ ! -t 1 ]]; then
    return 0
  fi

  local frames='|/-\\'
  local i=0
  while kill -0 "$pid" 2>/dev/null; do
    local frame="${frames:i%4:1}"
    printf "\r%s %s" "$message" "$frame"
    i=$((i + 1))
    sleep 0.2
  done
  printf "\r%-80s\r" ""
}

# logger_cmd()
# サブコマンド呼び出しの証跡をタイムスタンプ付きで出力する
# stdout と RDC_LOG_FILE（設定時）の両方へ記録する
# args: subcommand [argv...]
logger_cmd() {
  local subcmd="${1:-}"
  shift || true
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local invocation="rdw"
  [[ "${RDC_FORCE:-}" == "true" ]] && invocation+=" --force"
  [[ "${RDC_VERBOSE:-}" == "true" ]] && invocation+=" --verbose"
  invocation+=" ${subcmd}"
  [[ $# -gt 0 ]] && invocation+=" $*"
  local line="[$ts][CMD] $invocation"
  if [[ -n "${RDC_LOG_FILE:-}" ]]; then
    mkdir -p "$(dirname "${RDC_LOG_FILE}")" 2>/dev/null || true
    echo "$line" >> "${RDC_LOG_FILE}" 2>/dev/null || true
  fi
}
