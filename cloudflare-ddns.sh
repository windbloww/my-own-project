#!/usr/bin/env bash
set -uo pipefail

APP="cf-ddns"
CF_API="https://api.cloudflare.com/client/v4"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/$APP"
CONFIG_FILE="$CONFIG_DIR/config.json"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/$APP"
LOG_FILE="$STATE_DIR/ddns.log"
INSTALL_DIR="${HOME}/.local/bin"
INSTALL_PATH="$INSTALL_DIR/cf-ddns"
CRON_MARK="# cf-ddns managed task"
DEFAULT_INTERVAL=5

mkdir -p "$CONFIG_DIR" "$STATE_DIR"
chmod 700 "$CONFIG_DIR" "$STATE_DIR" 2>/dev/null || true

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log() { printf '[%s] %s\n' "$(ts)" "$*" | tee -a "$LOG_FILE"; }
die() { log "错误: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1; }

check_deps() {
  local missing=()
  for c in curl jq; do need "$c" || missing+=("$c"); done
  if ((${#missing[@]})); then
    echo "缺少依赖: ${missing[*]}"
    echo "Debian/Ubuntu/Linux Mint: sudo apt update && sudo apt install -y curl jq cron"
    exit 1
  fi
}

api() {
  local method="$1" endpoint="$2" data="${3:-}" token
  token="$(jq -r '.token // empty' "$CONFIG_FILE" 2>/dev/null || true)"
  [[ -n "$token" ]] || die "还没有配置 Cloudflare API Token"
  local -a args=(
    -fsS --connect-timeout 8 --max-time 25
    -X "$method"
    -H "Authorization: Bearer $token"
    -H "Content-Type: application/json"
  )
  [[ -n "$data" ]] && args+=(--data "$data")
  curl "${args[@]}" "${CF_API}${endpoint}"
}

api_with_token() {
  local token="$1" method="$2" endpoint="$3"
  curl -fsS --connect-timeout 8 --max-time 25     -X "$method"     -H "Authorization: Bearer $token"     -H "Content-Type: application/json"     "${CF_API}${endpoint}"
}

cf_ok() {
  local resp="$1" action="$2"
  if [[ "$(jq -r '.success // false' <<<"$resp")" != "true" ]]; then
    echo "$action 失败：$(jq -c '.errors // []' <<<"$resp" 2>/dev/null || echo '未知错误')" >&2
    return 1
  fi
}

get_ipv4() {
  local ip
  ip="$(curl -4 -fsS --connect-timeout 5 --max-time 10 https://api.ipify.org 2>/dev/null || true)"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  printf '%s' "$ip"
}

get_ipv6() {
  local ip
  ip="$(curl -6 -fsS --connect-timeout 5 --max-time 10 https://api64.ipify.org 2>/dev/null || true)"
  [[ "$ip" == *:* ]] || return 1
  printf '%s' "$ip"
}

save_config() {
  local token="$1" zone_id="$2" zone_name="$3" host="$4" types_json="$5" proxied="$6" interval="$7"
  local tmp
  tmp="$(mktemp)"
  jq -n     --arg token "$token"     --arg zone_id "$zone_id"     --arg zone_name "$zone_name"     --arg host "$host"     --argjson types "$types_json"     --argjson proxied "$proxied"     --argjson interval "$interval"     '{token:$token,zone_id:$zone_id,zone_name:$zone_name,host:$host,types:$types,proxied:$proxied,interval:$interval}' > "$tmp"
  mv "$tmp" "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"
}

install_cron() {
  local interval current line
  interval="$(jq -r '.interval // 5' "$CONFIG_FILE")"
  if ! need crontab; then
    echo "⚠️  未找到 crontab，自动更新尚未安装。"
    echo "   Debian/Ubuntu/Linux Mint 可执行: sudo apt install -y cron"
    return 1
  fi
  mkdir -p "$INSTALL_DIR"
  if [[ "$(readlink -f "$0")" != "$(readlink -f "$INSTALL_PATH" 2>/dev/null || true)" ]]; then
    cp "$0" "$INSTALL_PATH"
    chmod 700 "$INSTALL_PATH"
  fi
  current="$(crontab -l 2>/dev/null || true)"
  current="$(printf '%s\n' "$current" | awk -v mark="$CRON_MARK" 'index($0,mark)==0')"
  line="*/${interval} * * * * ${INSTALL_PATH} --update >/dev/null 2>&1 ${CRON_MARK}"
  { printf '%s\n' "$current"; printf '%s\n' "$line"; } | awk 'NF' | crontab -
  echo "✅ 已设置每 ${interval} 分钟自动检查并更新 DDNS"
}

setup() {
  clear 2>/dev/null || true
  echo "=========================================="
  echo "       Cloudflare DDNS 一键配置向导"
  echo "=========================================="
  echo
  echo "你只需要准备一个 Cloudflare API Token。"
  echo "Token 权限：Zone / DNS / Edit + Zone / Zone / Read"
  echo

  local token verify zones count choice zone_id zone_name label host type_choice types_json proxy_choice proxied interval
  while true; do
    read -rsp "粘贴 API Token: " token; echo
    [[ -n "$token" ]] || { echo "Token 不能为空。"; continue; }
    verify="$(api_with_token "$token" GET '/user/tokens/verify' 2>/dev/null || true)"
    if [[ "$(jq -r '.success // false' <<<"$verify" 2>/dev/null || echo false)" == "true" && "$(jq -r '.result.status // empty' <<<"$verify" 2>/dev/null)" == "active" ]]; then
      echo "✅ Token 有效"
      break
    fi
    echo "❌ Token 无效，请重新复制。"
  done

  zones="$(api_with_token "$token" GET '/zones?status=active&per_page=50&order=name&direction=asc' 2>/dev/null || true)"
  cf_ok "$zones" "读取域名列表" || {
    echo "请确认 Token 同时具有 Zone → Zone → Read 权限。"
    exit 1
  }
  count="$(jq '.result | length' <<<"$zones")"
  (( count > 0 )) || die "这个 Token 看不到任何已激活的 Cloudflare Zone"

  echo
  echo "请选择要做 DDNS 的域名："
  jq -r '.result | to_entries[] | "  \(.key+1)) \(.value.name)"' <<<"$zones"
  while true; do
    read -rp "输入序号: " choice
    [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= count)) && break
    echo "请输入 1~${count}。"
  done
  zone_id="$(jq -r ".result[$((choice-1))].id" <<<"$zones")"
  zone_name="$(jq -r ".result[$((choice-1))].name" <<<"$zones")"

  echo
  read -rp "DDNS 主机名前缀 [默认 ddns；根域名填 @]: " label
  label="${label:-ddns}"
  if [[ "$label" == "@" ]]; then
    host="$zone_name"
  elif [[ "$label" == *".$zone_name" ]]; then
    host="$label"
  else
    host="${label}.${zone_name}"
  fi

  echo
  echo "IP 类型："
  echo "  1) IPv4 / A     （推荐，默认）"
  echo "  2) IPv6 / AAAA"
  echo "  3) IPv4 + IPv6"
  read -rp "请选择 [1]: " type_choice
  type_choice="${type_choice:-1}"
  case "$type_choice" in
    1) types_json='["A"]' ;;
    2) types_json='["AAAA"]' ;;
    3) types_json='["A","AAAA"]' ;;
    *) echo "无效选择"; exit 1 ;;
  esac

  echo
  read -rp "开启 Cloudflare 橙云代理？[y/N，SSH/远程访问建议 N]: " proxy_choice
  [[ "$proxy_choice" =~ ^[Yy]$ ]] && proxied=true || proxied=false

  echo
  read -rp "每隔多少分钟检查 IP？[默认 ${DEFAULT_INTERVAL}]: " interval
  interval="${interval:-$DEFAULT_INTERVAL}"
  [[ "$interval" =~ ^[0-9]+$ ]] && ((interval >= 1 && interval <= 59)) || interval="$DEFAULT_INTERVAL"

  save_config "$token" "$zone_id" "$zone_name" "$host" "$types_json" "$proxied" "$interval"
  echo
  echo "正在创建/同步 DNS 记录……"
  update_all
  install_cron || true

  echo
  echo "=========================================="
  echo "✅ DDNS 配置完成"
  echo "域名: $host"
  echo "类型: $(jq -r '.types | join(" + ")' "$CONFIG_FILE")"
  echo "间隔: ${interval} 分钟"
  echo "配置: $CONFIG_FILE"
  echo "日志: $LOG_FILE"
  echo "=========================================="
}

upsert_record() {
  local type="$1" zone_id host proxied ip resp record_id old old_proxy data
  zone_id="$(jq -r '.zone_id' "$CONFIG_FILE")"
  host="$(jq -r '.host' "$CONFIG_FILE")"
  proxied="$(jq -r '.proxied' "$CONFIG_FILE")"

  if [[ "$type" == "A" ]]; then
    ip="$(get_ipv4 || true)"
  else
    ip="$(get_ipv6 || true)"
  fi
  if [[ -z "$ip" ]]; then
    log "[$type] $host: 获取公网地址失败，跳过"
    return 1
  fi

  resp="$(api GET "/zones/${zone_id}/dns_records?type=${type}&name=${host}&per_page=1" 2>/dev/null || true)"
  cf_ok "$resp" "查询 $type 记录" || return 1
  record_id="$(jq -r '.result[0].id // empty' <<<"$resp")"

  if [[ -z "$record_id" ]]; then
    data="$(jq -nc --arg t "$type" --arg n "$host" --arg c "$ip" --argjson p "$proxied" '{type:$t,name:$n,content:$c,ttl:1,proxied:$p}')"
    resp="$(api POST "/zones/${zone_id}/dns_records" "$data" 2>/dev/null || true)"
    cf_ok "$resp" "创建 $type 记录" || return 1
    log "[$type] $host: 已创建 -> $ip"
    return 0
  fi

  old="$(jq -r '.result[0].content // empty' <<<"$resp")"
  old_proxy="$(jq -r '.result[0].proxied // false' <<<"$resp")"
  if [[ "$old" == "$ip" && "$old_proxy" == "$proxied" ]]; then
    log "[$type] $host: 无变化 ($ip)"
    return 0
  fi

  data="$(jq -nc --arg t "$type" --arg n "$host" --arg c "$ip" --argjson p "$proxied" '{type:$t,name:$n,content:$c,ttl:1,proxied:$p}')"
  resp="$(api PATCH "/zones/${zone_id}/dns_records/${record_id}" "$data" 2>/dev/null || true)"
  cf_ok "$resp" "更新 $type 记录" || return 1
  log "[$type] $host: ${old:-无} -> $ip，更新成功"
}

update_all() {
  [[ -f "$CONFIG_FILE" ]] || die "尚未配置，请先运行 cf-ddns"
  local rc=0 type
  while IFS= read -r type; do
    upsert_record "$type" || rc=1
  done < <(jq -r '.types[]' "$CONFIG_FILE")
  return "$rc"
}

status() {
  [[ -f "$CONFIG_FILE" ]] || { echo "尚未配置。运行 cf-ddns 开始配置。"; return; }
  echo "Cloudflare DDNS"
  echo "  域名: $(jq -r '.host' "$CONFIG_FILE")"
  echo "  类型: $(jq -r '.types | join(" + ")' "$CONFIG_FILE")"
  echo "  橙云: $(jq -r 'if .proxied then "开启" else "关闭" end' "$CONFIG_FILE")"
  echo "  间隔: $(jq -r '.interval' "$CONFIG_FILE") 分钟"
  echo "  配置: $CONFIG_FILE"
  echo "  日志: $LOG_FILE"
  echo
  if need crontab && crontab -l 2>/dev/null | grep -Fq "$CRON_MARK"; then
    echo "  自动更新: ✅ 已启用"
  else
    echo "  自动更新: ⚠️ 未启用"
  fi
  echo
  echo "最近日志："
  tail -n 8 "$LOG_FILE" 2>/dev/null || echo "  暂无日志"
}

menu() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    setup
    return
  fi
  while true; do
    echo
    echo "========== Cloudflare DDNS =========="
    echo "1) 立即更新一次"
    echo "2) 查看状态"
    echo "3) 重新配置"
    echo "4) 查看完整日志"
    echo "0) 退出"
    echo "====================================="
    read -rp "请选择: " c
    case "$c" in
      1) update_all ;;
      2) status ;;
      3) setup ;;
      4) less "$LOG_FILE" 2>/dev/null || cat "$LOG_FILE" 2>/dev/null || true ;;
      0) exit 0 ;;
      *) echo "无效选择" ;;
    esac
  done
}

main() {
  check_deps
  case "${1:-}" in
    --update) update_all ;;
    --setup) setup ;;
    --status) status ;;
    --help|-h)
      echo "用法: cf-ddns [--setup|--update|--status]"
      ;;
    "") menu ;;
    *) echo "未知参数: $1"; exit 2 ;;
  esac
}

main "$@"
