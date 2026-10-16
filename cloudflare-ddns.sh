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
  # curl ... | bash 会占用 stdin，交互统一从终端读取。
  if ! { exec 3</dev/tty; } 2>/dev/null; then
    die "当前没有交互终端。请在 SSH 或终端窗口中运行安装命令。"
  fi
  local token='' verify zones count choice zone_id zone_name label host mode types_json
  echo '=== Cloudflare DDNS 简易配置 ==='
  echo '创建 Token：https://dash.cloudflare.com/profile/api-tokens'
  echo '所需权限：Zone → Zone → Read、Zone → DNS → Edit'
  echo
  local attempt
  for attempt in 1 2 3; do
    printf '请输入 API Token：' >&2
    if ! IFS= read -rs -u 3 token; then
      die '终端输入已结束，配置已退出'
    fi
    printf '\n' >&2
    if [[ -z "$token" ]]; then
      echo 'Token 不能为空。' >&2
      continue
    fi
    verify="$(api_with_token "$token" GET '/user/tokens/verify' 2>/dev/null || true)"
    if [[ "$(jq -r '.success // false' <<<"$verify" 2>/dev/null)" == true &&
          "$(jq -r '.result.status // empty' <<<"$verify" 2>/dev/null)" == active ]]; then
      break
    fi
    echo 'Token 验证失败，请检查 Token 或网络' >&2
    token=''
  done
  [[ -n "$token" ]] || die '验证失败次数过多，请重新运行'

  zones="$(api_with_token "$token" GET '/zones?status=active&per_page=50' 2>/dev/null || true)"
  cf_ok "$zones" '读取域名列表' || die '请确认 Token 有 Zone Read 权限'
  count="$(jq '.result | length' <<<"$zones")"
  (( count > 0 )) || die '没有查询到域名，请检查 Token 的域名权限'
  if (( count == 1 )); then
    choice=1
  else
    echo '选择你的 Cloudflare 域名：'
    jq -r '.result | to_entries[] | "  \(.key + 1)) \(.value.name)"' <<<"$zones"
    printf '请输入序号：' >&2
    IFS= read -r -u 3 choice || die '输入已结束，已退出'
    [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= count )) || die '域名序号无效'
  fi
  zone_id="$(jq -r ".result[$((choice-1))].id" <<<"$zones")"
  zone_name="$(jq -r ".result[$((choice-1))].name" <<<"$zones")"
  echo "已选域名：$zone_name"

  printf '子域名前缀 [默认 ddns，根域名输入 @]：' >&2
  IFS= read -r -u 3 label || die '输入已结束，已退出'
  label="${label:-ddns}"
  if [[ "$label" == '@' ]]; then
    host="$zone_name"
  elif [[ "$label" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*$ ]]; then
    if [[ "$label" == *".$zone_name" ]]; then host="$label"; else host="$label.$zone_name"; fi
  else
    die '子域名格式不正确'
  fi

  echo 'IP 类型：1) IPv4（默认）  2) IPv6  3) 双栈'
  printf '请选择 [1]：' >&2
  IFS= read -r -u 3 mode || die '输入已结束，已退出'
  case "${mode:-1}" in
    1) types_json='["A"]' ;;
    2) types_json='["AAAA"]' ;;
    3) types_json='["A","AAAA"]' ;;
    *) die 'IP 类型无效' ;;
  esac

  # DNS only（灰云），每 5 分钟检查，省去其他设置。
  save_config "$token" "$zone_id" "$zone_name" "$host" "$types_json" false 5
  echo '正在同步 Cloudflare DNS ...'
  if update_all; then
    echo '✅ DNS 同步成功'
  else
    echo '⚠ DNS 尚未全部同步，请检查网络或 Token 权限' >&2
  fi
  if install_cron; then
    echo "✅ 已完成：$host（灰云，每 5 分钟检查）"
  else
    echo '⚠ cron 未启用，安装 cron 后再运行一次配置' >&2
  fi
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
    read -rp "请选择: " c || exit 0
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
