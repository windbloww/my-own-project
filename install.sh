#!/usr/bin/env bash
set -euo pipefail

REPO="windbloww/my-own-project"
SCRIPT_PATH="cloudflare-ddns.sh"
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
  local here
  here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
  if [[ -n "$here" && -f "$here/cloudflare-ddns.sh" ]]; then
    cp "$here/cloudflare-ddns.sh" "$TMP"
    return 0
  fi

  if ! command -v gh >/dev/null 2>&1; then
    say "这个安装器来自 GitHub 私有仓库，需要 GitHub CLI (gh) 读取脚本。"
    say "请先安装并登录 gh，然后重新执行一键命令："
    say "  gh auth login"
    exit 1
  fi
  if ! gh auth status >/dev/null 2>&1; then
    say "GitHub CLI 尚未登录。请先执行：gh auth login"
    exit 1
  fi

  gh api "repos/${REPO}/contents/${SCRIPT_PATH}" --jq '.content' | tr -d '\n' | base64 -d > "$TMP"
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
