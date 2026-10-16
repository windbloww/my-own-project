#!/usr/bin/env bash
set -euo pipefail

RAW_BASE="https://raw.githubusercontent.com/windbloww/my-own-project/main"
INSTALL_DIR="$HOME/.local/bin"
INSTALL_PATH="$INSTALL_DIR/cf-ddns"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

say() { printf '%s\n' "$*"; }

install_deps() {
  local missing=0
  command -v curl >/dev/null 2>&1 || missing=1
  command -v jq >/dev/null 2>&1 || missing=1
  command -v crontab >/dev/null 2>&1 || missing=1
  (( missing == 0 )) && return 0

  say "检测到缺少依赖，尝试自动安装 curl / jq / cron..."
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update
    sudo apt-get install -y curl jq cron
  elif command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y curl jq cronie
    sudo systemctl enable --now crond 2>/dev/null || true
  elif command -v yum >/dev/null 2>&1; then
    sudo yum install -y curl jq cronie
    sudo systemctl enable --now crond 2>/dev/null || true
  elif command -v pacman >/dev/null 2>&1; then
    sudo pacman -Sy --noconfirm curl jq cronie
    sudo systemctl enable --now cronie 2>/dev/null || true
  else
    say "无法识别包管理器，请先手动安装 curl、jq 和 cron/cronie。"
    exit 1
  fi
}

fetch_script() {
  curl -fsSL "$RAW_BASE/cloudflare-ddns.sh" -o "$TMP"
}

main() {
  install_deps
  fetch_script
  bash -n "$TMP"
  mkdir -p "$INSTALL_DIR"
  install -m 700 "$TMP" "$INSTALL_PATH"

  say ""
  say "✅ cf-ddns 已安装到 $INSTALL_PATH"
  say "现在进入首次配置。"
  say ""
  "$INSTALL_PATH" --setup
  say ""
  say "以后随时运行：$INSTALL_PATH"
}

main "$@"
