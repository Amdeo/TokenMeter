#!/usr/bin/env bash
# 起一个只监听本机的静态服务并在浏览器打开卡片预览页（幂等：重复跑会复用/重启）。
#
# 用法:
#   bash scripts/preview.sh <目录> [文件名]     # 默认文件 index.html
#   bash scripts/preview.sh --stop             # 停掉服务
#
# 只依赖系统自带 python3（stdlib http.server），不装任何东西。
set -euo pipefail

STATE_DIR="${TMPDIR:-/tmp}/tokenmeter-card-preview"
PID_FILE="${STATE_DIR}/http.pid"
PORT_FILE="${STATE_DIR}/http.port"
LOG_FILE="${STATE_DIR}/http.log"
PORT_START="${PREVIEW_PORT_START:-8765}"
PORT_SCAN="${PREVIEW_PORT_SCAN:-40}"

mkdir -p "${STATE_DIR}"

stop_server() {
  if [[ -f "${PID_FILE}" ]]; then
    local pid
    pid="$(cat "${PID_FILE}")"
    if kill -0 "${pid}" 2>/dev/null; then
      kill "${pid}" 2>/dev/null || true
      echo "已停止预览服务（pid ${pid}）"
    else
      echo "预览服务已不在运行（pid ${pid}）"
    fi
    rm -f "${PID_FILE}" "${PORT_FILE}"
  else
    echo "没有正在运行的预览服务"
  fi
}

if [[ "${1:-}" == "--stop" ]]; then
  stop_server
  exit 0
fi

DIR="${1:?用法: preview.sh <目录> [文件名] | preview.sh --stop}"
FILE="${2:-index.html}"

if [[ ! -f "${DIR}/${FILE}" ]]; then
  echo "ERROR: 找不到 ${DIR}/${FILE}" >&2
  exit 1
fi

DIR="$(cd "${DIR}" && pwd)"

# 端口已被上一次运行的同一服务占用时直接复用；否则从 PORT_START 起找空闲端口。
PORT=""
if [[ -f "${PORT_FILE}" ]] && [[ -f "${PID_FILE}" ]] && kill -0 "$(cat "${PID_FILE}")" 2>/dev/null; then
  PORT="$(cat "${PORT_FILE}")"
else
  for offset in $(seq 0 $((PORT_SCAN - 1))); do
    candidate=$((PORT_START + offset))
    if ! lsof -nP -iTCP:"${candidate}" -sTCP:LISTEN >/dev/null 2>&1; then
      PORT="${candidate}"
      break
    fi
  done
fi

if [[ -z "${PORT}" ]]; then
  echo "ERROR: ${PORT_START}–$((PORT_START + PORT_SCAN - 1)) 全部被占用，用 PREVIEW_PORT_START 换个起始端口" >&2
  exit 1
fi

URL="http://127.0.0.1:${PORT}/${FILE}"

if [[ -f "${PORT_FILE}" ]] && [[ "$(cat "${PORT_FILE}")" == "${PORT}" ]] && curl -sf --max-time 1 "${URL}" >/dev/null 2>&1; then
  echo "预览服务已在运行：${URL}"
else
  # --bind 127.0.0.1：只监听本机，不暴露到局域网。
  nohup python3 -m http.server "${PORT}" --bind 127.0.0.1 --directory "${DIR}" >"${LOG_FILE}" 2>&1 &
  echo "$!" >"${PID_FILE}"
  echo "${PORT}" >"${PORT_FILE}"

  for _ in $(seq 1 10); do
    curl -sf --max-time 1 "${URL}" >/dev/null 2>&1 && break
    sleep 0.5
  done
  if ! curl -sf --max-time 1 "${URL}" >/dev/null 2>&1; then
    echo "ERROR: 预览服务没起来，日志：${LOG_FILE}" >&2
    exit 1
  fi
  echo "预览服务已启动：${URL}"
fi

echo "服务目录：${DIR}"
open "${URL}"
echo "改完 HTML 直接刷新浏览器即可；收工用：bash $0 --stop"
