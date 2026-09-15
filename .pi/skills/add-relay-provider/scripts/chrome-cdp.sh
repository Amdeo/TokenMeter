#!/usr/bin/env bash
# 确保本机 Chrome 以 CDP 端口监听（默认 9222），供 playwright-cli attach 探测中转站余额接口。
#
# 用法: bash scripts/chrome-cdp.sh [port]
# 退出码: 0 = CDP 就绪且 playwright-cli 可用；1 = 需要人工处理（输出里带 ACTION REQUIRED）
#
# 可覆盖的环境变量:
#   CDP_PORT          端口，默认 9222（等价的第一个位置参数优先）
#   CDP_PROFILE_DIR   调试实例的 user-data-dir，默认 ~/Library/Application Support/chrome-cdp-profile
#   CDP_SKIP_QUIT=1   不退出正在运行的 Google Chrome（不想被打断时用）
#   CDP_WAIT_SECONDS  等待端口就绪的秒数，默认 20
set -euo pipefail

PORT="${1:-${CDP_PORT:-9222}}"
PROFILE_DIR="${CDP_PROFILE_DIR:-$HOME/Library/Application Support/chrome-cdp-profile}"
CHROME_BIN="${CHROME_BIN:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
BROWSER_URL="http://127.0.0.1:${PORT}"
WAIT_SECONDS="${CDP_WAIT_SECONDS:-20}"
LOG_FILE="${TMPDIR:-/tmp}/chrome-cdp-${PORT}.log"

cdp_ready() { curl -sf --max-time 1 "${BROWSER_URL}/json/version" >/dev/null 2>&1; }
chrome_running() { pgrep -f "Google Chrome.app/Contents/MacOS/Google Chrome" >/dev/null 2>&1; }

manual_hint() {
  cat >&2 <<EOF

ACTION REQUIRED — 自动启动未成功，请手动执行下面这行，再重跑本脚本：

  "${CHROME_BIN}" --remote-debugging-port=${PORT} --user-data-dir="${PROFILE_DIR}" \\
    --no-first-run --no-default-browser-check

在弹出的 Chrome 里登录站点（余额页）后，重跑本脚本应输出 "CDP ready"。
注意：Chrome 136+ 已禁止在默认 profile 上开启远程调试，必须带 --user-data-dir；
      调试实例是独立 profile，站点登录态与你的日常 Chrome 不共享。
EOF
}

if cdp_ready; then
  echo "CDP ready: ${BROWSER_URL}（复用已在监听的实例，未改动任何 Chrome 进程）"
else
  if [[ "${CDP_SKIP_QUIT:-0}" != "1" ]] && chrome_running; then
    echo "正在退出运行中的 Google Chrome（标签页靠会话恢复）..."
    osascript -e 'quit app "Google Chrome"' >/dev/null 2>&1 || true
    for _ in $(seq 1 8); do chrome_running || break; sleep 1; done
    chrome_running && echo "warn: Chrome 仍在运行，继续尝试启动调试实例"
  fi

  mkdir -p "${PROFILE_DIR}"
  echo "启动调试 Chrome: ${BROWSER_URL}（profile: ${PROFILE_DIR}，日志: ${LOG_FILE}）"
  nohup "${CHROME_BIN}" \
    --remote-debugging-port="${PORT}" \
    --user-data-dir="${PROFILE_DIR}" \
    --no-first-run --no-default-browser-check >"${LOG_FILE}" 2>&1 &

  for _ in $(seq 1 "${WAIT_SECONDS}"); do cdp_ready && break; sleep 1; done
  if ! cdp_ready; then
    echo "ERROR: ${BROWSER_URL} 在 ${WAIT_SECONDS}s 内未就绪（日志: ${LOG_FILE}）" >&2
    manual_hint
    exit 1
  fi
  echo "CDP ready: ${BROWSER_URL}"
fi

if command -v playwright-cli >/dev/null 2>&1; then
  echo "playwright-cli: $(command -v playwright-cli) v$(playwright-cli --version 2>/dev/null | tr -d 'v ')"
  echo "下一步: playwright-cli -s=relay attach --cdp=${BROWSER_URL}"
else
  cat >&2 <<'EOF'

ACTION REQUIRED — 未安装 playwright-cli。不要静默安装，先向用户确认，再执行：

  npm install -g @playwright/cli@latest

（可选替代：chrome-devtools MCP 若可用，以其 --browserUrl 形态连 9222 同样能完成探测。）
EOF
  exit 1
fi
