#!/usr/bin/env bash
# =============================================================================
#  NXR · Realm 转发管理面板
#  面向 IX 转发：前置 → IX/中转 → 落地，多节点链路在一台机器上一键下发
#  项目: https://github.com/NX2406/nx-realm
#  realm: https://github.com/zhboner/realm
# =============================================================================
[ -z "${BASH_VERSION:-}" ] && { echo "请使用 bash 运行本脚本" >&2; exit 1; }
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then echo "需要 bash 4.0 及以上版本" >&2; exit 1; fi

NXR_VERSION="1.2.1"
NXR_REPO="NX2406/nx-realm"
NXR_RAW_URL="https://raw.githubusercontent.com/${NXR_REPO}/main/nxr.sh"
REALM_REPO="zhboner/realm"
REALM_FALLBACK_VERSION="v2.9.6"

NXR_DIR="/etc/nxr"
RULE_DIR="$NXR_DIR/rules"
REALM_CONF_DIR="$NXR_DIR/realm"
NODE_DIR="$NXR_DIR/nodes"
CHAIN_DIR="$NXR_DIR/chains"
SSH_DIR="$NXR_DIR/ssh"
GLOBAL_CONF="$NXR_DIR/nxr.conf"
CACHE_DIR="/var/cache/nxr"
LOG_DIR="/var/log/nxr"
BACKUP_DIR="/root"
REALM_BIN="/usr/local/bin/realm"
NXR_BIN="/usr/local/bin/nxr"
SYSTEMD_UNIT="/etc/systemd/system/nxr@.service"
WATCH_SERVICE="/etc/systemd/system/nxr-watch.service"
WATCH_TIMER="/etc/systemd/system/nxr-watch.timer"
OPENRC_SCRIPT="/etc/init.d/nxr"
NXR_KEY="$SSH_DIR/id_ed25519"
KNOWN_HOSTS="$SSH_DIR/known_hosts"
ACCT_TABLE="nxr_acct"
SYSCTL_FILE="/etc/sysctl.d/99-nxr-forward.conf"
LOCK_FILE="/run/nxr.lock"
REMOTE_NXR="/usr/local/bin/nxr"

GH_PROXIES=("https://ghfast.top/" "https://gh-proxy.com/" "https://ghproxy.net/")

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
  C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YLW=$'\e[33m'
  C_CYN=$'\e[36m'; C_GRY=$'\e[90m'; C_BLD=$'\e[1m'; C_RST=$'\e[0m'
else
  C_RED=''; C_GRN=''; C_YLW=''; C_CYN=''; C_GRY=''; C_BLD=''; C_RST=''
fi

ASSUME_YES=0
QUIET=0
OPT_FORCE=0
OPT_NO_FW=0
OPT_PURGE=0
COMMIT_RESTORED=0
INIT=none

# 全局设置（可在面板设置中修改，保存在 /etc/nxr/nxr.conf）
LOG_LEVEL="warn"
AUTO_FW="1"
DEFAULT_LISTEN="auto"
GH_PROXY="auto"
REALM_LIBC="musl"
REALM_OWNED="0"
GLOBAL_KEYS=(LOG_LEVEL AUTO_FW DEFAULT_LISTEN GH_PROXY REALM_LIBC REALM_OWNED)

# ------------------------------------------------------------------ 输出 / 交互
ok()   { printf '%s[✓]%s %s\n' "$C_GRN" "$C_RST" "$*" >&2; }
info() { [[ $QUIET == 1 ]] && return 0; printf '%s[*]%s %s\n' "$C_CYN" "$C_RST" "$*" >&2; }
warn() { printf '%s[!]%s %s\n' "$C_YLW" "$C_RST" "$*" >&2; }
err()  { printf '%s[✗]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; }
die()  { err "$*"; exit 1; }
hr()   { printf '%s%s%s\n' "$C_GRY" "  ──────────────────────────────────────────────────────────" "$C_RST"; }
clear_screen() { if [[ -t 1 ]]; then clear; fi; }
title() { clear_screen; printf '\n  %s%s%s\n' "$C_CYN$C_BLD" "$*" "$C_RST"; hr; }

pause() {
  [[ -t 0 ]] || return 0
  local _
  read -r -p "  按回车键继续..." _ || true
}

# ask 变量名 "提示" [默认值]（非交互环境直接取默认值）
ask() {
  local __v=$1 __p=$2 __d=${3-} __a=""
  if [[ ! -t 0 ]]; then
    printf -v "$__v" '%s' "$__d"
    return 0
  fi
  if [[ -n $__d ]]; then
    read -r -e -p "  $__p [${__d}]: " __a || return 1
  else
    read -r -e -p "  $__p: " __a || return 1
  fi
  __a=${__a#"${__a%%[![:space:]]*}"}
  __a=${__a%"${__a##*[![:space:]]}"}
  [[ -z $__a ]] && __a=$__d
  printf -v "$__v" '%s' "$__a"
}

# confirm "提示" [Y|N]
confirm() {
  local def=${2:-N} a hint='[y/N]'
  [[ $def == Y ]] && hint='[Y/n]'
  if [[ $ASSUME_YES == 1 ]]; then return 0; fi
  if [[ ! -t 0 ]]; then [[ $def == Y ]]; return; fi
  read -r -p "  $1 $hint: " a || return 1
  a=${a:-$def}
  [[ $a == [Yy]* ]]
}

# 附带操作（如卸载时删配置、删 realm）：-y 只确认主操作，这里取默认值；--purge 时一律执行
confirm_opt() {
  if [[ $OPT_PURGE == 1 ]]; then return 0; fi
  if [[ $ASSUME_YES == 1 ]]; then [[ ${2:-N} == Y ]]; return; fi
  confirm "$@"
}

read_choice() {
  local __v=$1 __a
  read -r -e -p "  ${2:-请输入选项}: " __a || { echo; exit 0; }
  printf -v "$__v" '%s' "$__a"
}

need_root() { [[ $EUID -eq 0 ]] || die "请使用 root 运行（可先执行 sudo -i）"; }
has() { command -v "$1" >/dev/null 2>&1; }
# ss 去掉表头（老版本 iproute2 不支持 -H）
ssq() { ss "$@" 2>/dev/null | awk 'NR > 1'; }

# ------------------------------------------------------------------ 校验
is_uint() { [[ $1 =~ ^[0-9]+$ ]]; }
is_port() { [[ $1 =~ ^[1-9][0-9]{0,4}$ ]] && (( $1 <= 65535 )); }
is_ipv4() {
  [[ $1 =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  local i
  for i in 1 2 3 4; do (( 10#${BASH_REMATCH[i]} <= 255 )) || return 1; done
}
is_ipv6() { [[ ( $1 == *:*:* || $1 == *::* ) && $1 =~ ^[0-9A-Fa-f:.]+(%[A-Za-z0-9_.-]+)?$ ]]; }
is_ip() { is_ipv4 "$1" || is_ipv6 "$1"; }
is_hostname() {
  [[ $1 =~ ^[A-Za-z0-9]([A-Za-z0-9_.-]{0,251}[A-Za-z0-9])?$ ]] || return 1
  [[ $1 =~ ^[0-9.]+$ || $1 == *..* ]] && return 1
  return 0
}
is_host() { is_ip "$1" || is_hostname "$1"; }
is_iface() { [[ $1 =~ ^[A-Za-z0-9_.:-]{1,15}$ ]]; }
is_name() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,31}$ ]]; }
is_text() { [[ ${#1} -le 64 && ! $1 =~ [[:cntrl:]] && $1 != *'|'* ]]; }
RE_TRANSPORT='^[A-Za-z0-9_.;=/:@,?&%+~-]+$'
is_transport() { [[ $1 =~ $RE_TRANSPORT ]]; }

# 解析 host:port 或 [IPv6]:port → HP_HOST / HP_PORT
split_hostport() {
  HP_HOST=""; HP_PORT=""
  if [[ $1 =~ ^\[([0-9A-Fa-f:.]+)\]:([0-9]+)$ ]]; then
    HP_HOST=${BASH_REMATCH[1]}; HP_PORT=${BASH_REMATCH[2]}
  elif [[ $1 =~ ^([^:]+):([0-9]+)$ ]]; then
    HP_HOST=${BASH_REMATCH[1]}; HP_PORT=${BASH_REMATCH[2]}
  else
    return 1
  fi
  is_host "$HP_HOST" && is_port "$HP_PORT"
}
join_hostport() {
  if [[ $1 == *:* ]]; then printf '[%s]:%s' "$1" "$2"; else printf '%s:%s' "$1" "$2"; fi
}

# ver_gt A B：版本号 A 是否高于 B（按点分段比较数字）
ver_gt() {
  local -a va vb
  local i x y
  IFS=. read -ra va <<<"${1#v}"
  IFS=. read -ra vb <<<"${2#v}"
  for i in 0 1 2 3; do
    x=${va[i]//[!0-9]/}; y=${vb[i]//[!0-9]/}
    (( 10#${x:-0} > 10#${y:-0} )) && return 0
    (( 10#${x:-0} < 10#${y:-0} )) && return 1
  done
  return 1
}

# 只读 HTTP GET，输出到 stdout
http_get() {
  if has curl; then
    curl -fsSL --connect-timeout 6 --max-time "${2:-15}" "$1" 2>/dev/null
  elif has wget; then
    wget -qO- -T "${2:-15}" "$1" 2>/dev/null
  else
    return 1
  fi
}

fmt_bytes() {
  awk -v b="${1:-0}" 'BEGIN{ split("B KB MB GB TB PB", u, " "); i = 1
    while (b >= 1024 && i < 6) { b /= 1024; i++ }
    if (i == 1) printf "%d%s", b, u[i]; else printf "%.2f%s", b, u[i] }'
}

now_us() {
  if [[ -n ${EPOCHREALTIME:-} ]]; then
    local t=${EPOCHREALTIME/[.,]/}
    echo "$t"
  else
    local t
    t=$(date +%s%N 2>/dev/null)
    if [[ $t =~ ^[0-9]{16,}$ ]]; then echo $(( t / 1000 )); else echo $(( $(date +%s) * 1000000 )); fi
  fi
}

# tcp_probe 主机 端口 [超时秒] → 输出建连耗时(ms)，失败返回 1；计时在子进程内完成，不含进程启动开销
tcp_probe() {
  local h=$1 p=$2 t=${3:-3} d
  h=${h#[}; h=${h%]}
  d=$(timeout "$t" bash -c '
    if [[ -n ${EPOCHREALTIME:-} ]]; then
      s=${EPOCHREALTIME/[.,]/}; exec 3<>"/dev/tcp/$1/$2" || exit 1; e=${EPOCHREALTIME/[.,]/}
    else
      s=$(date +%s%N); exec 3<>"/dev/tcp/$1/$2" || exit 1; e=$(date +%s%N); s=$((s / 1000)); e=$((e / 1000))
    fi
    echo $((e - s))' _ "$h" "$p" 2>/dev/null) || return 1
  [[ $d =~ ^[0-9]+$ ]] || return 1
  awk -v d="$d" 'BEGIN { printf "%.1f\n", d / 1000 }'
}

# ------------------------------------------------------------------ 系统 / 包管理
pkg_mgr() {
  local m
  for m in apt-get dnf yum apk pacman zypper; do has "$m" && { echo "$m"; return 0; }; done
  return 1
}

pkg_install() {
  local m
  m=$(pkg_mgr) || return 1
  case $m in
    apt-get)
      DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" >/dev/null 2>&1 || {
        apt-get update -y >/dev/null 2>&1
        DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" >/dev/null 2>&1
      } ;;
    dnf) dnf install -y "$@" >/dev/null 2>&1 ;;
    yum) yum install -y "$@" >/dev/null 2>&1 ;;
    apk) apk add --no-cache "$@" >/dev/null 2>&1 ;;
    pacman) pacman -Sy --noconfirm --needed "$@" >/dev/null 2>&1 ;;
    zypper) zypper -n install "$@" >/dev/null 2>&1 ;;
  esac
}

# ensure_cmd 命令 [包名...]：缺失时尝试安装
ensure_cmd() {
  local c=$1; shift
  has "$c" && return 0
  info "安装依赖: ${*:-$c}"
  if [[ $# -gt 0 ]]; then pkg_install "$@"; else pkg_install "$c"; fi
  has "$c"
}

ensure_base_deps() {
  has curl || ensure_cmd curl curl || has wget || warn "缺少 curl/wget，在线下载功能不可用"
  if ! has ss; then
    case $(pkg_mgr) in
      dnf|yum) ensure_cmd ss iproute ;;
      *) ensure_cmd ss iproute2 ;;
    esac || warn "缺少 ss 命令（iproute2），端口检测不可用"
  fi
  has tar || ensure_cmd tar tar || true
  has timeout || ensure_cmd timeout coreutils || true
}

detect_init() {
  if [[ -d /run/systemd/system ]] && has systemctl; then
    INIT=systemd
  elif has openrc-run || [[ -x /sbin/openrc-run ]]; then
    INIT=openrc
  else
    INIT=none
  fi
}

ipv6_ok() {
  [[ -f /proc/net/if_inet6 ]] && [[ $(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null) != 1 ]]
}

default_listen_addr() {
  case $DEFAULT_LISTEN in
    auto|"") if ipv6_ok; then echo '::'; else echo '0.0.0.0'; fi ;;
    *) echo "$DEFAULT_LISTEN" ;;
  esac
}

# 本机全局地址: "网卡 地址/前缀"
local_ifaces() {
  ip -o addr show scope global 2>/dev/null | awk '{print $2, $4}'
}

PUBLIC_IP_CACHE=""
public_ipv4() {
  [[ -n $PUBLIC_IP_CACHE ]] && { echo "$PUBLIC_IP_CACHE"; return 0; }
  local u ip
  for u in https://4.ipw.cn https://api.ipify.org https://ipv4.ip.sb; do
    ip=$(curl -4 -fsS --max-time 4 "$u" 2>/dev/null | tr -d '[:space:]')
    if is_ipv4 "$ip"; then PUBLIC_IP_CACHE=$ip; echo "$ip"; return 0; fi
  done
  return 1
}

# ------------------------------------------------------------------ 下载（含 GitHub 加速回退）
dl() {
  local url=$1 out=$2 t=${3:-60}
  if has curl; then
    curl -fsSL --connect-timeout 8 --max-time "$t" -o "$out" "$url"
  elif has wget; then
    wget -q -T 15 -O "$out" "$url"
  else
    return 1
  fi
}

gh_dl() {
  local url=$1 out=$2 t=${3:-120} p
  case $GH_PROXY in
    none) dl "$url" "$out" "$t" ;;
    auto|"")
      dl "$url" "$out" "$t" && return 0
      for p in "${GH_PROXIES[@]}"; do
        info "GitHub 直连失败，尝试加速: ${p}"
        dl "${p}${url}" "$out" "$t" && return 0
      done
      return 1 ;;
    *) dl "${GH_PROXY%/}/${url}" "$out" "$t" || dl "$url" "$out" "$t" ;;
  esac
}

# ------------------------------------------------------------------ 键值文件
kv_load() { # kv_load 文件 变量前缀 键...
  local f=$1 pre=$2 k v keys
  shift 2
  keys=" $* "
  [[ -f $f ]] || return 1
  while IFS='=' read -r k v || [[ -n $k ]]; do
    if [[ -n $k && $keys == *" $k "* ]]; then printf -v "$pre$k" '%s' "$v"; fi
  done < "$f"
  return 0
}

kv_save() { # kv_save 文件 变量前缀 键...
  local f=$1 pre=$2 k var tmp
  shift 2
  tmp="$f.tmp.$$"
  { for k in "$@"; do var="$pre$k"; printf '%s=%s\n' "$k" "${!var-}"; done; } > "$tmp" && mv -f "$tmp" "$f"
}

load_global() {
  [[ -f $GLOBAL_CONF ]] || return 0
  kv_load "$GLOBAL_CONF" "" "${GLOBAL_KEYS[@]}"
}

save_global() { kv_save "$GLOBAL_CONF" "" "${GLOBAL_KEYS[@]}"; }

init_dirs() {
  mkdir -p "$RULE_DIR" "$REALM_CONF_DIR" "$NODE_DIR" "$CHAIN_DIR" "$CACHE_DIR" "$LOG_DIR" "$SSH_DIR"
  chmod 700 "$NXR_DIR" "$SSH_DIR" 2>/dev/null
  [[ -f $GLOBAL_CONF ]] || save_global
}

# busybox 的 flock 没有 -w，用 -n 轮询等待（最多约 15 秒）
with_lock() {
  if has flock; then
    (
      __n=0
      until flock -n 9; do
        (( __n++ < 60 )) || exit 1
        sleep 0.25
      done
      "$@"
    ) 9>"$LOCK_FILE"
  else
    "$@"
  fi
}

# ================================================================== 规则存储
RULE_KEYS=(ID NAME LISTEN_ADDR LISTEN_PORT REMOTE EXTRA_REMOTES BALANCE HEALTH DOWN BACKUPS ACTIVE_REMOTE SWITCHBACK
           PROTO THROUGH IFACE LISTEN_IFACE LISTEN_TRANSPORT REMOTE_TRANSPORT SEND_PROXY ACCEPT_PROXY
           DNS_MODE TCP_TIMEOUT UDP_TIMEOUT ENABLED CHAIN ROLE FW_OPENED CREATED ALLOW)

rule_reset() {
  local k
  for k in "${RULE_KEYS[@]}"; do printf -v "R_$k" '%s' ''; done
  R_PROTO="both"; R_ENABLED="1"; R_SWITCHBACK="1"; R_SEND_PROXY="0"; R_ACCEPT_PROXY="0"; R_FW_OPENED="0"; R_HEALTH="0"
}
rule_path() { printf '%s/%s.conf' "$RULE_DIR" "$1"; }
rule_exists() { is_port "$1" && [[ -f $(rule_path "$1") ]]; }
rule_load() { rule_reset; is_port "$1" && kv_load "$(rule_path "$1")" R_ "${RULE_KEYS[@]}"; }
rule_save() { mkdir -p "$RULE_DIR"; kv_save "$(rule_path "$R_ID")" R_ "${RULE_KEYS[@]}"; }
rule_ids() {
  local f
  for f in "$RULE_DIR"/*.conf; do
    [[ -f $f ]] || continue
    f=${f##*/}
    echo "${f%.conf}"
  done | sort -n
}
rule_count() { rule_ids | grep -c . ; }

proto_label() {
  case $1 in tcp) echo "TCP";; udp) echo "UDP";; *) echo "TCP+UDP";; esac
}
proto_short() {
  case $1 in tcp) echo "T";; udp) echo "U";; *) echo "T+U";; esac
}

# 规则当前实际使用的目标（主备切换后可能是备用目标）
rule_target() { echo "${R_ACTIVE_REMOTE:-$R_REMOTE}"; }

toml_array() {
  local IFS=, item out=""
  for item in $1; do
    [[ -z $item ]] && continue
    out+="${out:+, }\"$item\""
  done
  printf '[%s]' "$out"
}

# 负载均衡池去掉不可用成员后的 remote / extra_remotes / balance → RT_REMOTE RT_EXTRA RT_BALANCE
render_targets() {
  local strat i
  local -a pool ws act=() aw=()
  RT_REMOTE=$(rule_target); RT_EXTRA=""; RT_BALANCE=""
  [[ -n $R_EXTRA_REMOTES ]] || return 0
  IFS=, read -ra pool <<<"$R_REMOTE,$R_EXTRA_REMOTES"
  strat=${R_BALANCE%%:*}
  IFS=, read -ra ws <<<"$(tr -d ' ' <<<"${R_BALANCE#*:}")"
  for i in "${!pool[@]}"; do
    if [[ $R_HEALTH == 1 && ",$R_DOWN," == *",${pool[i]},"* ]]; then continue; fi
    act+=("${pool[i]}"); aw+=("${ws[i]:-1}")
  done
  if [[ ${#act[@]} -eq 0 ]]; then act=("${pool[@]}"); aw=("${ws[@]}"); fi
  RT_REMOTE=${act[0]}
  if [[ ${#act[@]} -gt 1 ]]; then
    RT_EXTRA=$(IFS=,; echo "${act[*]:1}")
    RT_BALANCE="$strat: $(IFS=,; echo "${aw[*]}" | sed 's/,/, /g')"
  fi
}

# 生成 realm 配置（每条规则一个独立进程，互不影响）
rule_render() {
  mkdir -p "$REALM_CONF_DIR"
  local f="$REALM_CONF_DIR/$R_ID.toml" tmp no_tcp=false use_udp=true
  case $R_PROTO in
    tcp) use_udp=false ;;
    udp) no_tcp=true ;;
  esac
  tmp="$f.tmp.$$"
  {
    echo "# 由 nxr 生成（规则 $R_ID），请用 nxr 修改，手动修改会被覆盖"
    echo "[log]"
    echo "level = \"${LOG_LEVEL:-warn}\""
    if [[ -n $R_DNS_MODE ]]; then
      printf '\n[dns]\nmode = "%s"\n' "$R_DNS_MODE"
    fi
    printf '\n[network]\nno_tcp = %s\nuse_udp = %s\n' "$no_tcp" "$use_udp"
    if [[ -n $R_TCP_TIMEOUT ]]; then echo "tcp_timeout = $R_TCP_TIMEOUT"; fi
    if [[ -n $R_UDP_TIMEOUT ]]; then echo "udp_timeout = $R_UDP_TIMEOUT"; fi
    if [[ $R_SEND_PROXY == 1 ]]; then printf 'send_proxy = true\nsend_proxy_version = 2\n'; fi
    if [[ $R_ACCEPT_PROXY == 1 ]]; then printf 'accept_proxy = true\naccept_proxy_timeout = 5\n'; fi
    printf '\n[[endpoints]]\n'
    printf 'listen = "%s"\n' "$(join_hostport "$R_LISTEN_ADDR" "$R_LISTEN_PORT")"
    render_targets
    printf 'remote = "%s"\n' "$RT_REMOTE"
    if [[ -n $RT_EXTRA ]]; then
      printf 'extra_remotes = %s\n' "$(toml_array "$RT_EXTRA")"
      printf 'balance = "%s"\n' "$RT_BALANCE"
    fi
    if [[ -n $R_THROUGH ]]; then printf 'through = "%s"\n' "$R_THROUGH"; fi
    if [[ -n $R_IFACE ]]; then printf 'interface = "%s"\n' "$R_IFACE"; fi
    if [[ -n $R_LISTEN_IFACE ]]; then printf 'listen_interface = "%s"\n' "$R_LISTEN_IFACE"; fi
    if [[ -n $R_LISTEN_TRANSPORT ]]; then printf 'listen_transport = "%s"\n' "$R_LISTEN_TRANSPORT"; fi
    if [[ -n $R_REMOTE_TRANSPORT ]]; then printf 'remote_transport = "%s"\n' "$R_REMOTE_TRANSPORT"; fi
  } > "$tmp" && mv -f "$tmp" "$f"
}

# 补全负载均衡写法：roundrobin / iphash → "roundrobin: 1, 1, ..."
normalize_balance() {
  local n=$1 b=$2 s w out="" i
  local -a arr
  [[ -z $b ]] && return 0
  s=${b%%:*}; s=${s// /}
  if [[ $b == *:* ]]; then
    w=${b#*:}; w=${w// /}
  else
    w=""
    for (( i = 0; i < n; i++ )); do w+="${w:+,}1"; done
  fi
  [[ $s == roundrobin || $s == iphash ]] || return 1
  [[ $w =~ ^[0-9]{1,3}(,[0-9]{1,3})*$ ]] || return 1
  IFS=, read -ra arr <<<"$w"
  [[ ${#arr[@]} -eq $n ]] || return 1
  for i in "${arr[@]}"; do (( 10#$i <= 255 )) || return 1; out+="${out:+, }$((10#$i))"; done
  echo "$s: $out"
}

valid_hostport_list() {
  local IFS=, x
  for x in $1; do split_hostport "$x" || return 1; done
}

rule_validate() {
  is_port "$R_LISTEN_PORT" || { err "监听端口无效: ${R_LISTEN_PORT:-空}"; return 1; }
  R_LISTEN_PORT=$((10#$R_LISTEN_PORT))
  [[ -z $R_LISTEN_ADDR ]] && R_LISTEN_ADDR=$(default_listen_addr)
  R_LISTEN_ADDR=${R_LISTEN_ADDR#[}; R_LISTEN_ADDR=${R_LISTEN_ADDR%]}
  is_ip "$R_LISTEN_ADDR" || { err "监听地址无效: $R_LISTEN_ADDR"; return 1; }
  split_hostport "$R_REMOTE" || { err "目标地址无效（格式 host:port 或 [IPv6]:port）: ${R_REMOTE:-空}"; return 1; }
  if [[ -n $R_EXTRA_REMOTES ]]; then
    R_EXTRA_REMOTES=${R_EXTRA_REMOTES// /}
    valid_hostport_list "$R_EXTRA_REMOTES" || { err "负载均衡目标无效: $R_EXTRA_REMOTES"; return 1; }
    local n
    n=$(( $(tr -cd ',' <<<"$R_EXTRA_REMOTES" | wc -c) + 2 ))
    [[ -z $R_BALANCE ]] && R_BALANCE="roundrobin"
    R_BALANCE=$(normalize_balance "$n" "$R_BALANCE") || { err "负载均衡策略无效（roundrobin/iphash，权重个数需为 $n）"; return 1; }
    [[ $R_HEALTH == 1 ]] || R_HEALTH=0
    if [[ -n $R_DOWN ]]; then
      local x keep=""
      local -a downs
      IFS=, read -ra downs <<<"$R_DOWN"
      for x in "${downs[@]}"; do
        if [[ ",$R_REMOTE,$R_EXTRA_REMOTES," == *",$x,"* ]]; then keep+="${keep:+,}$x"; fi
      done
      R_DOWN=$keep
    fi
  else
    R_BALANCE=""; R_HEALTH=0; R_DOWN=""
  fi
  if [[ -n $R_EXTRA_REMOTES && -n $R_BACKUPS ]]; then
    err "负载均衡和主备切换只能二选一（负载均衡开启健康检查后同样能自动绕开故障目标）"
    return 1
  fi
  if [[ -n $R_BACKUPS ]]; then
    R_BACKUPS=${R_BACKUPS// /}
    valid_hostport_list "$R_BACKUPS" || { err "备用目标无效: $R_BACKUPS"; return 1; }
    [[ $R_SWITCHBACK == 0 || $R_SWITCHBACK == 1 ]] || R_SWITCHBACK=1
  else
    R_ACTIVE_REMOTE=""
  fi
  if [[ -n $R_ACTIVE_REMOTE && $R_ACTIVE_REMOTE != "$R_REMOTE" && ",$R_BACKUPS," != *",$R_ACTIVE_REMOTE,"* ]]; then
    R_ACTIVE_REMOTE=""
  fi
  case $R_PROTO in both|tcp|udp) ;; tcp+udp|all) R_PROTO=both ;; *) err "协议无效: $R_PROTO（both/tcp/udp）"; return 1 ;; esac
  if [[ -n $R_THROUGH ]]; then is_ip "$R_THROUGH" || { err "出站源 IP 无效: $R_THROUGH"; return 1; }; fi
  if [[ -n $R_IFACE ]]; then is_iface "$R_IFACE" || { err "出站网卡名无效: $R_IFACE"; return 1; }; fi
  if [[ -n $R_LISTEN_IFACE ]]; then is_iface "$R_LISTEN_IFACE" || { err "入站网卡名无效: $R_LISTEN_IFACE"; return 1; }; fi
  if [[ -n $R_LISTEN_TRANSPORT ]]; then is_transport "$R_LISTEN_TRANSPORT" || { err "监听传输参数无效"; return 1; }; fi
  if [[ -n $R_REMOTE_TRANSPORT ]]; then is_transport "$R_REMOTE_TRANSPORT" || { err "出站传输参数无效"; return 1; }; fi
  if [[ $R_PROTO == udp && ( -n $R_LISTEN_TRANSPORT || -n $R_REMOTE_TRANSPORT ) ]]; then
    err "加密传输（tls/ws）只作用于 TCP，仅 UDP 规则不能启用"; return 1
  fi
  case $R_DNS_MODE in ""|ipv4_only|ipv6_only|ipv4_then_ipv6|ipv6_then_ipv4|ipv4_and_ipv6) ;; *) err "DNS 策略无效: $R_DNS_MODE"; return 1 ;; esac
  if [[ -n $R_TCP_TIMEOUT ]]; then is_uint "$R_TCP_TIMEOUT" || { err "tcp_timeout 无效"; return 1; }; fi
  if [[ -n $R_UDP_TIMEOUT ]]; then is_uint "$R_UDP_TIMEOUT" || { err "udp_timeout 无效"; return 1; }; fi
  is_text "$R_NAME" || { err "名称过长或含非法字符（最多 64 字符，不能含 |）"; return 1; }
  if [[ -n $R_CHAIN ]]; then is_name "$R_CHAIN" || { err "链路 ID 无效: $R_CHAIN"; return 1; }; fi
  is_text "$R_ROLE" || { err "角色名无效"; return 1; }
  if [[ -n $R_ALLOW ]]; then
    local a acl=""
    local -a al
    IFS=, read -ra al <<<"${R_ALLOW// /}"
    for a in "${al[@]}"; do
      [[ -z $a ]] && continue
      is_cidr "$a" || { err "来源白名单地址无效: $a（写 IP 或 IP/前缀）"; return 1; }
      [[ ",$acl," == *",$a,"* ]] || acl+="${acl:+,}$a"
    done
    R_ALLOW=$acl
  fi
  [[ $R_ENABLED == 0 ]] || R_ENABLED=1
  R_ID=$R_LISTEN_PORT
  return 0
}

# ================================================================== 服务托管（systemd / OpenRC）
unit_content() {
  cat <<EOF
[Unit]
Description=NXR realm forward rule %i
Documentation=https://github.com/${NXR_REPO}
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStartPre=-${NXR_BIN} acct-sync --port %i
ExecStart=${REALM_BIN} -c ${REALM_CONF_DIR}/%i.toml
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

openrc_content() {
  cat <<'EOF'
#!/sbin/openrc-run
# NXR realm 规则服务，实例名 nxr.<规则ID>
rule="${RC_SVCNAME#nxr.}"
name="nxr realm rule ${rule}"
command="/usr/local/bin/realm"
command_args="-c /etc/nxr/realm/${rule}.toml"
supervisor="supervise-daemon"
respawn_delay=3
respawn_max=0
output_log="/var/log/nxr/${rule}.log"
error_log="/var/log/nxr/${rule}.log"
rc_ulimit="-n 1048576"

depend() {
  need net
  after firewall
}

start_pre() {
  if [ "$RC_SVCNAME" = "nxr" ]; then
    eerror "请使用实例 nxr.<规则ID>"
    return 1
  fi
  checkpath -d -m 0755 /var/log/nxr
  /usr/local/bin/nxr acct-sync --port "$rule" >/dev/null 2>&1 || true
}
EOF
}

svc_setup() {
  local tmp
  tmp=$(mktemp)
  case $INIT in
    systemd)
      unit_content > "$tmp"
      if ! cmp -s "$tmp" "$SYSTEMD_UNIT"; then
        install -m 644 "$tmp" "$SYSTEMD_UNIT"
        systemctl daemon-reload
      fi ;;
    openrc)
      openrc_content > "$tmp"
      if ! cmp -s "$tmp" "$OPENRC_SCRIPT"; then install -m 755 "$tmp" "$OPENRC_SCRIPT"; fi ;;
    *)
      rm -f "$tmp"
      err "未检测到 systemd 或 OpenRC，无法托管 realm 服务"
      return 1 ;;
  esac
  rm -f "$tmp"
}

svc_start_rule() {
  local id=$1
  case $INIT in
    systemd)
      systemctl enable "nxr@$id.service" >/dev/null 2>&1
      systemctl reset-failed "nxr@$id.service" >/dev/null 2>&1
      systemctl restart "nxr@$id.service" >/dev/null 2>&1 ;;
    openrc)
      ln -sf nxr "/etc/init.d/nxr.$id"
      rc-update add "nxr.$id" default >/dev/null 2>&1
      rc-service "nxr.$id" restart >/dev/null 2>&1 ;;
  esac
}

svc_stop_rule() {
  local id=$1
  case $INIT in
    systemd)
      systemctl disable --now "nxr@$id.service" >/dev/null 2>&1
      systemctl reset-failed "nxr@$id.service" >/dev/null 2>&1 ;;
    openrc)
      rc-service "nxr.$id" stop >/dev/null 2>&1
      rc-update del "nxr.$id" default >/dev/null 2>&1 ;;
  esac
  return 0
}

svc_remove_rule() {
  svc_stop_rule "$1"
  if [[ $INIT == openrc ]]; then rm -f "/etc/init.d/nxr.$1"; fi
  return 0
}

# 输出 active / activating / failed / inactive
svc_state() {
  local s
  case $INIT in
    systemd)
      s=$(systemctl is-active "nxr@$1.service" 2>/dev/null)
      echo "${s:-inactive}" ;;
    openrc)
      if rc-service "nxr.$1" status >/dev/null 2>&1; then echo active; else echo inactive; fi ;;
    *) echo inactive ;;
  esac
}

svc_logs() {
  local id=$1 n=${2:-30}
  case $INIT in
    systemd) journalctl -q -u "nxr@$id.service" -n "$n" --no-pager -o short-iso 2>/dev/null ;;
    openrc) tail -n "$n" "$LOG_DIR/$id.log" 2>/dev/null ;;
  esac
}

svc_follow() {
  case $INIT in
    systemd) journalctl -q -u "nxr@$1.service" -f -n 20 ;;
    openrc) tail -n 20 -f "$LOG_DIR/$1.log" ;;
  esac
}

# ================================================================== 端口检测
port_in_use() { [[ -n $(ssq -lntu "( sport = :$1 )") ]]; }
port_owner() {
  ssq -lntup "( sport = :$1 )" | grep -o 'users:(("[^"]*"' | head -1 | cut -d'"' -f2
}

# 规则端口是否由 realm 在监听
rule_listening() {
  local p=$1 proto=${2:-both} t u
  t=$(ssq -lntp "( sport = :$p )")
  u=$(ssq -lnup "( sport = :$p )")
  case $proto in
    tcp) [[ $t == *realm* ]] ;;
    udp) [[ $u == *realm* ]] ;;
    *) [[ $t == *realm* && $u == *realm* ]] ;;
  esac
}

random_free_port() {
  local p i
  for (( i = 0; i < 200; i++ )); do
    p=$(( (RANDOM * 32768 + RANDOM) % 50000 + 10000 ))
    rule_exists "$p" && continue
    port_in_use "$p" && continue
    echo "$p"
    return 0
  done
  return 1
}

conn_count() {
  ssq -tn state established "( sport = :$1 )" | grep -c .
}

# ================================================================== realm 安装
realm_triple() {
  local m=$1 libc=${2:-$REALM_LIBC}
  case $m in
    x86_64|amd64) echo "x86_64-unknown-linux-$libc" ;;
    aarch64|arm64) echo "aarch64-unknown-linux-$libc" ;;
    armv7*|armv8l)
      if [[ $libc == musl ]]; then echo "armv7-unknown-linux-musleabihf"; else echo "armv7-unknown-linux-gnueabihf"; fi ;;
    armv6*|arm)
      if [[ $libc == musl ]]; then echo "arm-unknown-linux-musleabihf"; else echo "arm-unknown-linux-gnueabihf"; fi ;;
    *) return 1 ;;
  esac
}

realm_version() {
  [[ -x $REALM_BIN ]] || return 1
  "$REALM_BIN" --version 2>/dev/null | awk 'NR==1{for(i=1;i<=NF;i++) if($i ~ /^v?[0-9]+\.[0-9]+/){sub(/^v/,"",$i); print $i; exit}}'
}

# 输出最新版本号；查询失败时输出内置版本并返回 2
realm_latest_tag() {
  local tag=""
  tag=$(http_get "https://api.github.com/repos/$REALM_REPO/releases/latest" 10 | grep -m1 '"tag_name"' | cut -d'"' -f4)
  if [[ -z $tag ]] && has curl; then
    tag=$(curl -fsSI --connect-timeout 6 --max-time 10 "https://github.com/$REALM_REPO/releases/latest" 2>/dev/null \
      | awk -F/ 'tolower($0) ~ /^location:/ {print $NF}' | tr -d '\r\n')
  fi
  if [[ $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then echo "$tag"; return 0; fi
  echo "$REALM_FALLBACK_VERSION"
  return 2
}

# GitHub 为发布附件提供的官方 SHA256（取不到时输出为空）
realm_digest() { # realm_digest 版本 文件名
  http_get "https://api.github.com/repos/$REALM_REPO/releases/tags/$1" 15 \
    | awk -v n="\"name\": \"$2\"" 'index($0, n) { f = 1; next }
        f && /"digest"/ { if (match($0, /sha256:[0-9a-f]+/)) print substr($0, RSTART + 7, RLENGTH - 7); exit }'
}

# realm_fetch 版本 三元组 输出文件
realm_fetch() {
  local tag=$1 triple=$2 out=$3 tmpd url want got
  tmpd=$(mktemp -d)
  url="https://github.com/$REALM_REPO/releases/download/$tag/realm-$triple.tar.gz"
  info "下载 realm $tag ($triple)"
  if ! gh_dl "$url" "$tmpd/realm.tar.gz" 180; then
    rm -rf "$tmpd"; err "下载失败：$url"; return 1
  fi
  want=$(realm_digest "$tag" "realm-$triple.tar.gz")
  if [[ ${#want} -eq 64 ]] && has sha256sum; then
    got=$(sha256sum "$tmpd/realm.tar.gz" | cut -d' ' -f1)
    if [[ $got != "$want" ]]; then
      rm -rf "$tmpd"; err "realm 压缩包 SHA256 与 GitHub 官方值不一致，已放弃安装"; return 1
    fi
    info "SHA256 校验通过"
  else
    warn "无法获取 GitHub 官方 SHA256（API 不可达），已跳过完整性校验"
  fi
  if ! tar -xzf "$tmpd/realm.tar.gz" -C "$tmpd" 2>/dev/null || [[ ! -f $tmpd/realm ]]; then
    rm -rf "$tmpd"; err "解压失败（下载内容可能不完整）"; return 1
  fi
  install -m 755 "$tmpd/realm" "$out"
  rm -rf "$tmpd"
}

# 取得指定版本/架构的 realm（优先缓存），输出文件路径
realm_cache_get() {
  local tag=$1 triple=$2 f
  f="$CACHE_DIR/realm-$tag-$triple"
  mkdir -p "$CACHE_DIR"
  if [[ ! -s $f ]]; then realm_fetch "$tag" "$triple" "$f" || { rm -f "$f"; return 1; }; fi
  echo "$f"
}

# 从本地文件取得 realm 二进制（支持 .tar.gz 或裸二进制）
realm_from_file() {
  local src=$1 out=$2 tmpd
  [[ -f $src ]] || { err "文件不存在: $src"; return 1; }
  if tar -tzf "$src" >/dev/null 2>&1; then
    tmpd=$(mktemp -d)
    tar -xzf "$src" -C "$tmpd" 2>/dev/null
    if [[ ! -f $tmpd/realm ]]; then rm -rf "$tmpd"; err "压缩包内没有 realm"; return 1; fi
    install -m 755 "$tmpd/realm" "$out"
    rm -rf "$tmpd"
  else
    install -m 755 "$src" "$out"
  fi
}

realm_restart_all() {
  local id
  for id in $(rule_ids); do
    rule_load "$id" || continue
    if [[ $R_ENABLED == 1 ]]; then svc_start_rule "$id"; fi
  done
}

# realm_install [--version vX.Y.Z] [--file 路径] [--libc musl|gnu] [--force] [--auto]
realm_install() {
  local tag="" file="" libc=$REALM_LIBC force=0 cur triple src newbin newv
  while [[ $# -gt 0 ]]; do
    case $1 in
      --version) tag=${2:-} ;;
      --file) file=${2:-} ;;
      --libc) libc=${2:-} ;;
      --force) force=1; shift; continue ;;
      *) shift; continue ;;
    esac
    shift
    [[ $# -gt 0 ]] && shift
  done
  [[ $libc == musl || $libc == gnu ]] || { err "--libc 只能是 musl 或 gnu"; return 1; }
  [[ -z $tag || $tag == v* ]] || tag="v$tag"
  cur=$(realm_version)
  newbin="$REALM_BIN.new.$$"
  if [[ -n $file ]]; then
    realm_from_file "$file" "$newbin" || return 1
  else
    if [[ -z $tag ]]; then
      if ! tag=$(realm_latest_tag) && [[ -n $cur ]]; then
        warn "无法从 GitHub 查询最新版本，保持当前 realm v$cur（指定版本可用 --version）"
        return 0
      fi
    fi
    if [[ $force == 0 && -n $cur && "v$cur" == "$tag" ]]; then
      ok "realm 已是 $tag，无需更新"
      return 0
    fi
    if [[ $force == 0 && -n $cur ]] && ver_gt "$cur" "$tag"; then
      ok "当前 realm v$cur 比 $tag 新，未降级（确需降级请加 --force）"
      return 0
    fi
    triple=$(realm_triple "$(uname -m)" "$libc") || { err "暂不支持的 CPU 架构: $(uname -m)"; return 1; }
    src=$(realm_cache_get "$tag" "$triple") || {
      err "无法下载 realm。若本机无法访问 GitHub，可上传 realm 压缩包后用：nxr install-realm --file /root/realm-xxx.tar.gz"
      return 1
    }
    install -m 755 "$src" "$newbin"
  fi
  if ! newv=$("$newbin" --version 2>/dev/null) || [[ -z $newv ]]; then
    rm -f "$newbin"
    err "realm 无法在本机运行（架构或 libc 不匹配？可在设置中切换 musl/gnu 构建）"
    return 1
  fi
  mv -f "$newbin" "$REALM_BIN"
  if [[ -z $cur ]]; then REALM_OWNED=1; save_global; fi
  ok "realm 已安装: $(realm_version)  ($REALM_BIN)"
  if [[ -n $cur && $(rule_count) -gt 0 ]]; then
    if [[ $ASSUME_YES == 1 ]] || confirm "重启全部规则以使用新版本（会短暂中断连接）?" Y; then
      realm_restart_all
      ok "已重启全部规则"
    fi
  fi
  return 0
}

ensure_realm() {
  [[ -x $REALM_BIN ]] && return 0
  info "未检测到 realm，开始自动安装"
  realm_install
}

# ================================================================== 防火墙
fw_backend() {
  if has ufw && LC_ALL=C ufw status 2>/dev/null | grep -q '^Status: active'; then echo ufw; return; fi
  if has firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then echo firewalld; return; fi
  if has iptables && iptables -w -S INPUT 2>/dev/null | grep -qE '^-P INPUT (DROP|REJECT)|-j (DROP|REJECT)'; then
    echo iptables; return
  fi
  echo none
}

fw_persist() {
  if has netfilter-persistent; then
    netfilter-persistent save >/dev/null 2>&1
  elif [[ -f /etc/sysconfig/iptables ]] && has iptables-save; then
    iptables-save > /etc/sysconfig/iptables 2>/dev/null
    if [[ -f /etc/sysconfig/ip6tables ]] && has ip6tables-save; then ip6tables-save > /etc/sysconfig/ip6tables 2>/dev/null; fi
  fi
  return 0
}

fw_protos() { case $1 in tcp) echo tcp ;; udp) echo udp ;; *) echo "tcp udp" ;; esac; }

# fw_open 端口 协议：输出 nxr 新放行的协议（如 tcp,udp），原本已放行的不算；没有防火墙返回 1
# firewalld 不做 --reload：iptables 后端下 reload 会清掉 Docker、fail2ban 等动态规则
fw_open() {
  local p=$1 b x t added=""
  b=$(fw_backend)
  case $b in
    ufw)
      for x in $(fw_protos "$2"); do
        LC_ALL=C ufw show added 2>/dev/null | grep -qE "^ufw allow ($p|$p/$x)( |$)" && continue
        { ufw allow "$p/$x" comment nxr >/dev/null 2>&1 || ufw allow "$p/$x" >/dev/null 2>&1; } && added+="${added:+,}$x"
      done ;;
    firewalld)
      for x in $(fw_protos "$2"); do
        firewall-cmd --query-port="$p/$x" >/dev/null 2>&1 && continue
        firewall-cmd --add-port="$p/$x" >/dev/null 2>&1 && added+="${added:+,}$x"
        firewall-cmd --permanent --add-port="$p/$x" >/dev/null 2>&1
      done ;;
    iptables)
      for x in $(fw_protos "$2"); do
        for t in iptables ip6tables; do
          has "$t" || continue
          "$t" -w -C INPUT -p "$x" --dport "$p" -m comment --comment nxr -j ACCEPT 2>/dev/null \
            || "$t" -w -I INPUT -p "$x" --dport "$p" -m comment --comment nxr -j ACCEPT 2>/dev/null
        done
        added+="${added:+,}$x"
      done
      fw_persist ;;
    *) return 1 ;;
  esac
  if [[ -n $added ]]; then info "防火墙($b) 已放行端口 $p（${added//,//}）"; fi
  echo "$added"
}

# fw_close 端口 nxr放行的协议（tcp,udp；旧记录的 1 表示 tcp 和 udp）
fw_close() {
  local p=$1 owned=${2:-} b x t changed=0
  [[ -z $owned || $owned == 0 ]] && return 0
  [[ $owned == 1 ]] && owned="tcp,udp"
  b=$(fw_backend)
  case $b in
    ufw) for x in ${owned//,/ }; do ufw delete allow "$p/$x" >/dev/null 2>&1; done ;;
    firewalld)
      for x in ${owned//,/ }; do
        firewall-cmd --remove-port="$p/$x" >/dev/null 2>&1
        firewall-cmd --permanent --remove-port="$p/$x" >/dev/null 2>&1
      done ;;
  esac
  for t in iptables ip6tables; do
    has "$t" || continue
    for x in ${owned//,/ }; do
      while "$t" -w -D INPUT -p "$x" --dport "$p" -m comment --comment nxr -j ACCEPT 2>/dev/null; do changed=1; done
    done
  done
  if [[ $changed == 1 ]]; then fw_persist; fi
  return 0
}

# 合并两个协议列表（tcp,udp）
fw_merge() {
  local x out=""
  for x in ${1//,/ } ${2//,/ }; do
    case $x in
      1) out=$(fw_merge "$out" "tcp,udp") ;;
      tcp|udp) [[ ",$out," == *",$x,"* ]] || out+="${out:+,}$x" ;;
    esac
  done
  echo "$out"
}

# ================================================================== 流量统计（nftables 优先，iptables 兜底）
acct_backend() {
  if has nft && nft list tables >/dev/null 2>&1; then echo nft
  elif has iptables; then echo ipt
  else echo none
  fi
}

acct_nft_table() {
  nft list table inet "$ACCT_TABLE" >/dev/null 2>&1 && return 0
  nft -f - >/dev/null 2>&1 <<EOF
table inet $ACCT_TABLE {
  chain nxr_in { type filter hook input priority -150; policy accept; }
  chain nxr_out { type filter hook output priority -150; policy accept; }
}
EOF
}

acct_nft_add() {
  local p=$1
  acct_nft_table || return 1
  nft list counter inet "$ACCT_TABLE" "in_$p" >/dev/null 2>&1 && return 0
  nft -f - >/dev/null 2>&1 <<EOF
add counter inet $ACCT_TABLE in_$p
add counter inet $ACCT_TABLE out_$p
add rule inet $ACCT_TABLE nxr_in tcp dport $p counter name "in_$p" comment "nxr:$p"
add rule inet $ACCT_TABLE nxr_in udp dport $p counter name "in_$p" comment "nxr:$p"
add rule inet $ACCT_TABLE nxr_out tcp sport $p counter name "out_$p" comment "nxr:$p"
add rule inet $ACCT_TABLE nxr_out udp sport $p counter name "out_$p" comment "nxr:$p"
EOF
}

acct_nft_del() {
  local p=$1 ch h
  nft list table inet "$ACCT_TABLE" >/dev/null 2>&1 || return 0
  for ch in nxr_in nxr_out; do
    for h in $(nft -a list chain inet "$ACCT_TABLE" "$ch" 2>/dev/null | grep -F "comment \"nxr:$p\"" | awk '{print $NF}'); do
      nft delete rule inet "$ACCT_TABLE" "$ch" handle "$h" >/dev/null 2>&1
    done
  done
  nft delete counter inet "$ACCT_TABLE" "in_$p" >/dev/null 2>&1
  nft delete counter inet "$ACCT_TABLE" "out_$p" >/dev/null 2>&1
  return 0
}

acct_nft_bytes() {
  nft list counter inet "$ACCT_TABLE" "$1" 2>/dev/null \
    | awk '{for(i=1;i<NF;i++) if($i=="bytes"){print $(i+1); exit}}'
}

acct_nft_ports() {
  nft list counters table inet "$ACCT_TABLE" 2>/dev/null | awk '$1=="counter" && $2 ~ /^in_[0-9]+$/ {sub(/^in_/,"",$2); print $2}'
}

# 统计链放在 mangle 表：filter 表里防火墙的 ACCEPT 规则可能排在统计跳转之前
acct_ipt_chains() {
  local t
  for t in iptables ip6tables; do
    has "$t" || continue
    acct_ipt_drop_filter "$t"
    "$t" -w -t mangle -N NXR_ACCT_IN 2>/dev/null
    "$t" -w -t mangle -N NXR_ACCT_OUT 2>/dev/null
    "$t" -w -t mangle -C INPUT -j NXR_ACCT_IN 2>/dev/null || "$t" -w -t mangle -I INPUT 1 -j NXR_ACCT_IN 2>/dev/null
    "$t" -w -t mangle -C OUTPUT -j NXR_ACCT_OUT 2>/dev/null || "$t" -w -t mangle -I OUTPUT 1 -j NXR_ACCT_OUT 2>/dev/null
  done
  return 0
}

# 删除早期版本建在 filter 表的统计链
acct_ipt_drop_filter() {
  local t=$1
  "$t" -w -S NXR_ACCT_IN >/dev/null 2>&1 || return 0
  "$t" -w -D INPUT -j NXR_ACCT_IN >/dev/null 2>&1
  "$t" -w -D OUTPUT -j NXR_ACCT_OUT >/dev/null 2>&1
  "$t" -w -F NXR_ACCT_IN >/dev/null 2>&1; "$t" -w -X NXR_ACCT_IN >/dev/null 2>&1
  "$t" -w -F NXR_ACCT_OUT >/dev/null 2>&1; "$t" -w -X NXR_ACCT_OUT >/dev/null 2>&1
  return 0
}

acct_ipt_add() {
  local p=$1 t x
  acct_ipt_chains
  for t in iptables ip6tables; do
    has "$t" || continue
    for x in tcp udp; do
      "$t" -w -t mangle -C NXR_ACCT_IN -p "$x" --dport "$p" -m comment --comment "nxr:$p" 2>/dev/null \
        || "$t" -w -t mangle -A NXR_ACCT_IN -p "$x" --dport "$p" -m comment --comment "nxr:$p" 2>/dev/null
      "$t" -w -t mangle -C NXR_ACCT_OUT -p "$x" --sport "$p" -m comment --comment "nxr:$p" 2>/dev/null \
        || "$t" -w -t mangle -A NXR_ACCT_OUT -p "$x" --sport "$p" -m comment --comment "nxr:$p" 2>/dev/null
    done
  done
  return 0
}

acct_ipt_del() {
  local p=$1 t x
  for t in iptables ip6tables; do
    has "$t" || continue
    for x in tcp udp; do
      while "$t" -w -t mangle -D NXR_ACCT_IN -p "$x" --dport "$p" -m comment --comment "nxr:$p" 2>/dev/null; do :; done
      while "$t" -w -t mangle -D NXR_ACCT_OUT -p "$x" --sport "$p" -m comment --comment "nxr:$p" 2>/dev/null; do :; done
    done
  done
  return 0
}

acct_ipt_bytes() { # 链 端口
  local chain=$1 p=$2 t sum=0 v
  for t in iptables ip6tables; do
    has "$t" || continue
    v=$("$t" -w -t mangle -nvxL "$chain" 2>/dev/null | awk -v c="/* nxr:$p */" 'index($0, c) {s += $2} END {print s + 0}')
    sum=$(( sum + ${v:-0} ))
  done
  echo "$sum"
}

acct_ipt_ports() {
  iptables -w -t mangle -nL NXR_ACCT_IN 2>/dev/null | grep -o '/\* nxr:[0-9]* \*/' | grep -o '[0-9]*' | sort -u
}

acct_ipt_remove_all() {
  local t
  for t in iptables ip6tables; do
    has "$t" || continue
    acct_ipt_drop_filter "$t"
    "$t" -w -t mangle -D INPUT -j NXR_ACCT_IN >/dev/null 2>&1
    "$t" -w -t mangle -D OUTPUT -j NXR_ACCT_OUT >/dev/null 2>&1
    "$t" -w -t mangle -F NXR_ACCT_IN >/dev/null 2>&1; "$t" -w -t mangle -X NXR_ACCT_IN >/dev/null 2>&1
    "$t" -w -t mangle -F NXR_ACCT_OUT >/dev/null 2>&1; "$t" -w -t mangle -X NXR_ACCT_OUT >/dev/null 2>&1
  done
  return 0
}

acct_add() {
  case $(acct_backend) in
    nft) acct_nft_add "$1" ;;
    ipt) acct_ipt_add "$1" ;;
  esac
  return 0
}

acct_del() {
  case $(acct_backend) in
    nft) acct_nft_del "$1" ;;
    ipt) acct_ipt_del "$1" ;;
  esac
  return 0
}

# 输出 "入站字节 出站字节"
acct_get() {
  local i=0 o=0
  case $(acct_backend) in
    nft) i=$(acct_nft_bytes "in_$1"); o=$(acct_nft_bytes "out_$1") ;;
    ipt) i=$(acct_ipt_bytes NXR_ACCT_IN "$1"); o=$(acct_ipt_bytes NXR_ACCT_OUT "$1") ;;
  esac
  echo "${i:-0} ${o:-0}"
}

acct_reset() {
  case $(acct_backend) in
    nft) nft reset counter inet "$ACCT_TABLE" "in_$1" >/dev/null 2>&1; nft reset counter inet "$ACCT_TABLE" "out_$1" >/dev/null 2>&1 ;;
    ipt) acct_ipt_del "$1"; acct_ipt_add "$1" ;;
  esac
  return 0
}

acct_sync_all() {
  local id p
  for id in $(rule_ids); do
    rule_load "$id" || continue
    if [[ $R_ENABLED == 1 ]]; then acct_add "$id"; fi
  done
  case $(acct_backend) in
    nft) for p in $(acct_nft_ports); do rule_exists "$p" || acct_nft_del "$p"; done ;;
    ipt) for p in $(acct_ipt_ports); do rule_exists "$p" || acct_ipt_del "$p"; done ;;
  esac
  return 0
}

# ================================================================== 来源 IP 白名单（IX/中转端口只接受上一跳）
ACL_TABLE="nxr_acl"

is_cidr() {
  local ip=${1%/*} p=""
  if [[ $1 == */* ]]; then p=${1#*/}; is_uint "$p" || return 1; fi
  if is_ipv4 "$ip"; then [[ -z $p ]] || (( 10#$p <= 32 ))
  elif is_ipv6 "$ip"; then [[ -z $p ]] || (( 10#$p <= 128 ))
  else return 1
  fi
}

# 拆成 IPv4 / IPv6 两组（逗号分隔），并始终放行本机回环
acl_split() {
  local x
  local -a xs
  ACL4="127.0.0.0/8"; ACL6="::1"
  IFS=, read -ra xs <<<"$1"
  for x in "${xs[@]}"; do
    [[ -z $x ]] && continue
    if [[ ${x%/*} == *:* ]]; then ACL6+=",$x"; else ACL4+=",$x"; fi
  done
}

acl_backend() {
  if has nft; then echo nft; elif has iptables; then echo ipt; else echo none; fi
}

acl_nft_del() {
  local p=$1 h s
  nft list table inet "$ACL_TABLE" >/dev/null 2>&1 || return 0
  for h in $(nft -a list chain inet "$ACL_TABLE" input 2>/dev/null | grep -F "comment \"nxr-acl:$p\"" | awk '{print $NF}'); do
    nft delete rule inet "$ACL_TABLE" input handle "$h" >/dev/null 2>&1
  done
  for s in "a4_$p" "a6_$p"; do nft delete set inet "$ACL_TABLE" "$s" >/dev/null 2>&1; done
  return 0
}

acl_nft_apply() {
  local p=$1 x
  acl_nft_del "$p"
  acl_split "$2"
  if ! nft list table inet "$ACL_TABLE" >/dev/null 2>&1; then
    nft -f - >/dev/null 2>&1 <<EOF || return 1
table inet $ACL_TABLE {
  chain input { type filter hook input priority -5; policy accept; }
}
EOF
  fi
  nft -f - <<EOF
add set inet $ACL_TABLE a4_$p { type ipv4_addr; flags interval; auto-merge; elements = { ${ACL4//,/, } } }
add set inet $ACL_TABLE a6_$p { type ipv6_addr; flags interval; auto-merge; elements = { ${ACL6//,/, } } }
add rule inet $ACL_TABLE input tcp dport $p ip saddr != @a4_$p drop comment "nxr-acl:$p"
add rule inet $ACL_TABLE input udp dport $p ip saddr != @a4_$p drop comment "nxr-acl:$p"
add rule inet $ACL_TABLE input tcp dport $p ip6 saddr != @a6_$p drop comment "nxr-acl:$p"
add rule inet $ACL_TABLE input udp dport $p ip6 saddr != @a6_$p drop comment "nxr-acl:$p"
EOF
}

acl_ipt_del() {
  local p=$1 t x c="NXR_ACL_$1"
  for t in iptables ip6tables; do
    has "$t" || continue
    for x in tcp udp; do
      while "$t" -D INPUT -p "$x" --dport "$p" -j "$c" 2>/dev/null; do :; done
    done
    "$t" -F "$c" 2>/dev/null
    "$t" -X "$c" 2>/dev/null
  done
  return 0
}

acl_ipt_apply() {
  local p=$1 t x list c="NXR_ACL_$1"
  local -a xs
  acl_ipt_del "$p"
  acl_split "$2"
  for t in iptables ip6tables; do
    has "$t" || continue
    if [[ $t == iptables ]]; then list=$ACL4; else list=$ACL6; fi
    "$t" -N "$c" 2>/dev/null || return 1
    IFS=, read -ra xs <<<"$list"
    for x in "${xs[@]}"; do "$t" -A "$c" -s "$x" -j RETURN; done
    "$t" -A "$c" -j DROP
    for x in tcp udp; do "$t" -I INPUT -p "$x" --dport "$p" -j "$c"; done
  done
  return 0
}

# 两套都清：机器后来装了 nftables 时，旧的 iptables 规则不能留下
acl_del() {
  if has nft; then acl_nft_del "$1"; fi
  if has iptables; then acl_ipt_del "$1"; fi
  return 0
}

# acl_apply 端口 白名单：白名单为空时移除该端口的限制
acl_apply() {
  local p=$1 list=$2
  acl_del "$p"
  if [[ -z $list ]]; then return 0; fi
  if [[ $(acl_backend) == none ]]; then
    ensure_cmd nft nftables >/dev/null 2>&1 || { warn "缺少 nft / iptables，端口 $p 的来源白名单未生效"; return 1; }
  fi
  case $(acl_backend) in
    nft) acl_nft_apply "$p" "$list" >/dev/null || { warn "端口 $p 的来源白名单写入失败"; return 1; } ;;
    ipt) acl_ipt_apply "$p" "$list" || { warn "端口 $p 的来源白名单写入失败"; return 1; } ;;
  esac
  return 0
}

# 服务启动时按规则文件重建白名单（重启后 nft / iptables 规则会丢失）
acl_sync_port() {
  local p=$1 f
  f=$(rule_path "$p")
  [[ -f $f ]] || { acl_del "$p"; return 0; }
  acl_apply "$p" "$(kv_get "$f" ALLOW)"
}

# 本机可能用来连接下一跳的源地址：各网卡全局地址 + 公网出口地址
cli_src_ips() {
  { local_ifaces | awk '{split($2, a, "/"); print a[1]}'; public_ipv4 2>/dev/null; } | grep -v '^$' | sort -u
}

# ================================================================== 规则生命周期
# 启动并确认 realm 已监听
rule_start_verify() {
  local id=$1 i st
  svc_start_rule "$id"
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    sleep 0.5
    if rule_listening "$id" "$R_PROTO"; then return 0; fi
  done
  st=$(svc_state "$id")
  err "规则 $id 启动失败（服务状态: $st），最近日志："
  svc_logs "$id" 15 | sed 's/^/      /' >&2
  return 1
}

# 删除规则（停止服务、清理配置/统计/防火墙）
rule_purge() {
  local id=$1
  rule_load "$id" || return 1
  svc_remove_rule "$id"
  fw_close "$id" "$R_FW_OPENED"
  with_lock acct_del "$id"
  with_lock acl_del "$id"
  rm -f "$(rule_path "$id")" "$REALM_CONF_DIR/$id.toml"
  return 0
}

# 用当前 R_* 创建/更新规则并生效；$1 = 原规则 ID（修改时）
# 新配置启动失败时保留/恢复原规则，并置 COMMIT_RESTORED=1
rule_commit() {
  local old_id=${1:-} rc snap="" f added
  COMMIT_RESTORED=0
  if [[ -n $old_id ]] && rule_exists "$old_id"; then
    f=$(rule_path "$old_id")
    if [[ $R_REMOTE != "$(kv_get "$f" REMOTE)" || $R_BACKUPS != "$(kv_get "$f" BACKUPS)" ]]; then R_ACTIVE_REMOTE=""; fi
    if [[ $R_REMOTE != "$(kv_get "$f" REMOTE)" || $R_EXTRA_REMOTES != "$(kv_get "$f" EXTRA_REMOTES)" ]]; then R_DOWN=""; fi
  fi
  rule_validate || return 2
  if [[ -z $old_id ]] && rule_exists "$R_ID"; then
    if [[ $OPT_FORCE == 1 ]]; then
      local keep_created
      keep_created=$(kv_get "$(rule_path "$R_ID")" CREATED)
      [[ -n $keep_created ]] && R_CREATED=$keep_created
    else
      err "端口 $R_ID 已有转发规则（如需覆盖请加 --force，或使用修改功能）"
      return 3
    fi
  fi
  if [[ -n $old_id && $old_id != "$R_ID" ]] && rule_exists "$R_ID"; then
    err "端口 $R_ID 已被其他规则使用"; return 3
  fi
  if [[ $R_ENABLED == 1 ]] && port_in_use "$R_ID"; then
    if ! { rule_exists "$R_ID" && [[ $(svc_state "$R_ID") == active ]]; }; then
      err "端口 $R_ID 已被其他程序占用: $(port_owner "$R_ID")"
      return 3
    fi
  fi
  has ss || ensure_base_deps >/dev/null 2>&1
  ensure_realm || return 4
  svc_setup || return 4
  if [[ -n $old_id && $old_id != "$R_ID" ]]; then R_FW_OPENED=0; fi
  if rule_exists "$R_ID"; then
    snap=$(mktemp -d)
    cp -p "$(rule_path "$R_ID")" "$snap/rule"
    if [[ -f $REALM_CONF_DIR/$R_ID.toml ]]; then cp -p "$REALM_CONF_DIR/$R_ID.toml" "$snap/toml"; fi
  fi
  [[ -z $R_CREATED ]] && R_CREATED=$(date '+%F %T')
  rule_save
  rule_render
  rc=0
  if [[ $R_ENABLED == 1 ]]; then
    with_lock acct_add "$R_ID"
    if rule_start_verify "$R_ID"; then
      if [[ $AUTO_FW == 1 && $OPT_NO_FW != 1 ]] && added=$(fw_open "$R_ID" "$R_PROTO") && [[ -n $added ]]; then
        R_FW_OPENED=$(fw_merge "$R_FW_OPENED" "$added")
        rule_save
      fi
      with_lock acl_apply "$R_ID" "$R_ALLOW"
      local more=""
      if [[ -n $R_EXTRA_REMOTES ]]; then more="（共 $(( $(tr -cd ',' <<<"$R_EXTRA_REMOTES" | wc -c) + 2 )) 个目标，$(mode_label "${R_BALANCE%%:*}")）"; fi
      if [[ -n $R_BACKUPS ]]; then more="（另有 $(( $(tr -cd ',' <<<"$R_BACKUPS" | wc -c) + 1 )) 个备用）"; fi
      ok "规则 $R_ID 已生效：$(join_hostport "$R_LISTEN_ADDR" "$R_LISTEN_PORT") → $(rule_target)$more  [$(proto_label "$R_PROTO")]"
    else
      rc=5
    fi
  else
    svc_stop_rule "$R_ID"
    ok "规则 $R_ID 已保存（停用状态）"
  fi
  if [[ $rc -eq 5 && -n $snap ]]; then
    cp -p "$snap/rule" "$(rule_path "$R_ID")"
    if [[ -f $snap/toml ]]; then cp -p "$snap/toml" "$REALM_CONF_DIR/$R_ID.toml"; fi
    rule_load "$R_ID"
    if [[ $R_ENABLED == 1 ]]; then svc_start_rule "$R_ID"; else svc_stop_rule "$R_ID"; fi
    COMMIT_RESTORED=1
    warn "新配置未能启动，已恢复规则 $R_ID 原来的配置"
  elif [[ $rc -eq 5 && -n $old_id && $old_id != "$R_ID" ]]; then
    rule_purge "$R_ID"
    COMMIT_RESTORED=1
    warn "新端口未能启动，原规则 $old_id 保持不变"
  elif [[ -n $old_id && $old_id != "$R_ID" ]]; then
    local fw_old
    fw_old=$(kv_get "$(rule_path "$old_id")" FW_OPENED)
    svc_remove_rule "$old_id"
    fw_close "$old_id" "$fw_old"
    with_lock acct_del "$old_id"
    with_lock acl_del "$old_id"
    rm -f "$(rule_path "$old_id")" "$REALM_CONF_DIR/$old_id.toml"
  fi
  if [[ -n $snap ]]; then rm -rf "$snap"; fi
  watch_setup
  return "$rc"
}

kv_get() { # kv_get 文件 键
  [[ -f $1 ]] || return 1
  awk -v k="$2" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' "$1"
}

rule_set_enabled() {
  local id=$1 en=$2
  rule_load "$id" || { err "规则不存在: $id"; return 1; }
  R_ENABLED=$en
  rule_commit "$id"
}

apply_all() {
  local id fails=0
  svc_setup || return 1
  for id in $(rule_ids); do
    rule_load "$id" || continue
    rule_render
    if [[ $R_ENABLED == 1 ]]; then
      with_lock acct_add "$id"
      rule_start_verify "$id" || fails=$((fails + 1))
    else
      svc_stop_rule "$id"
    fi
  done
  watch_setup
  [[ $fails -eq 0 ]]
}

# ================================================================== 主备切换巡检
probe_ok() { split_hostport "$1" || return 1; tcp_probe "$HP_HOST" "$HP_PORT" 2 >/dev/null; }

watch_switch() {
  local id=$1 to=$2 why=$3 from
  rule_load "$id" || return 1
  [[ $R_ENABLED == 1 && ",$R_REMOTE,$R_BACKUPS," == *",$to,"* ]] || return 0
  from=$(rule_target)
  [[ $from == "$to" ]] && return 0
  if [[ $to == "$R_REMOTE" ]]; then R_ACTIVE_REMOTE=""; else R_ACTIVE_REMOTE=$to; fi
  rule_save
  rule_render
  svc_start_rule "$id"
  printf '%s 规则 %s 切换 %s → %s（%s）\n' "$(date '+%F %T')" "$id" "$from" "$to" "$why" >> "$LOG_DIR/watch.log"
  info "规则 $id 已切换到 $to（$why）"
}

watch_run() {
  local id cur c cands
  if has flock; then
    exec 8>/run/nxr-watch.lock
    flock -n 8 || return 0
  fi
  for id in $(rule_ids); do
    rule_load "$id" || continue
    [[ $R_ENABLED == 1 && -n $R_BACKUPS && $R_PROTO != udp ]] || continue
    cur=$(rule_target)
    if probe_ok "$cur" || probe_ok "$cur" || probe_ok "$cur"; then
      if [[ $cur != "$R_REMOTE" && $R_SWITCHBACK == 1 ]] && probe_ok "$R_REMOTE" && probe_ok "$R_REMOTE"; then
        watch_switch "$id" "$R_REMOTE" "主目标已恢复"
      fi
      continue
    fi
    IFS=, read -ra cands <<<"$R_REMOTE,$R_BACKUPS"
    for c in "${cands[@]}"; do
      [[ -z $c || $c == "$cur" ]] && continue
      if probe_ok "$c"; then
        watch_switch "$id" "$c" "$cur 连续 3 次探测失败"
        break
      fi
    done
  done
  watch_health
  return 0
}

# 负载均衡健康检查：连续 3 次探测失败的成员摘除，连续 2 次成功再加回
watch_health() {
  local id x down old sig
  local -a pool
  for id in $(rule_ids); do
    rule_load "$id" || continue
    [[ $R_ENABLED == 1 && $R_HEALTH == 1 && -n $R_EXTRA_REMOTES && $R_PROTO != udp ]] || continue
    IFS=, read -ra pool <<<"$R_REMOTE,$R_EXTRA_REMOTES"
    sig="$R_REMOTE,$R_EXTRA_REMOTES"
    down=""
    for x in "${pool[@]}"; do
      if [[ ",$R_DOWN," == *",$x,"* ]]; then
        if probe_ok "$x" && probe_ok "$x"; then continue; fi
        down+="${down:+,}$x"
      elif ! { probe_ok "$x" || probe_ok "$x" || probe_ok "$x"; }; then
        down+="${down:+,}$x"
      fi
    done
    # 探测期间规则可能被修改/停用/删除，写回前重新读取
    rule_load "$id" || continue
    [[ $R_ENABLED == 1 && $R_HEALTH == 1 && "$R_REMOTE,$R_EXTRA_REMOTES" == "$sig" ]] || continue
    [[ $down == "$R_DOWN" ]] && continue
    old=$R_DOWN
    R_DOWN=$down
    rule_save
    rule_render
    svc_start_rule "$id"
    printf '%s 规则 %s 负载均衡池更新：不可用 [%s]（原 [%s]）\n' "$(date '+%F %T')" "$id" "${down:-无}" "${old:-无}" >> "$LOG_DIR/watch.log"
    info "规则 $id 负载均衡池已更新，不可用: ${down:-无}"
  done
}

watch_needed() {
  local id f
  for id in $(rule_ids); do
    f=$(rule_path "$id")
    [[ $(kv_get "$f" ENABLED) == 1 ]] || continue
    if [[ -n $(kv_get "$f" BACKUPS) ]]; then return 0; fi
    if [[ $(kv_get "$f" HEALTH) == 1 && -n $(kv_get "$f" EXTRA_REMOTES) ]]; then return 0; fi
  done
  return 1
}

watch_setup() {
  if watch_needed; then
    case $INIT in
      systemd)
        if [[ ! -f $WATCH_TIMER ]]; then
          cat > "$WATCH_SERVICE" <<EOF
[Unit]
Description=NXR realm failover and health check

[Service]
Type=oneshot
ExecStart=${NXR_BIN} watch
EOF
          cat > "$WATCH_TIMER" <<'EOF'
[Unit]
Description=NXR realm failover check timer

[Timer]
OnBootSec=60
OnUnitActiveSec=30
AccuracySec=5

[Install]
WantedBy=timers.target
EOF
          systemctl daemon-reload
        fi
        systemctl enable --now nxr-watch.timer >/dev/null 2>&1 ;;
      openrc)
        local cr=/etc/crontabs/root
        if ! grep -qs 'nxr watch' "$cr"; then
          mkdir -p /etc/crontabs
          echo "* * * * * $NXR_BIN watch >/dev/null 2>&1" >> "$cr"
          touch /etc/crontabs/cron.update
        fi
        if ! rc-service crond status >/dev/null 2>&1; then
          rc-update add crond default >/dev/null 2>&1
          rc-service crond start >/dev/null 2>&1 || warn "crond 未运行，主备切换/健康检查不会自动执行"
        fi ;;
    esac
  else
    case $INIT in
      systemd)
        if [[ -f $WATCH_TIMER ]]; then
          systemctl disable --now nxr-watch.timer >/dev/null 2>&1
          rm -f "$WATCH_TIMER" "$WATCH_SERVICE"
          systemctl daemon-reload
        fi ;;
      openrc)
        if grep -qs 'nxr watch' /etc/crontabs/root; then
          sed -i '/nxr watch/d' /etc/crontabs/root
          touch /etc/crontabs/cron.update
        fi ;;
    esac
  fi
  return 0
}

# ================================================================== 节点（SSH 多节点）
NODE_KEYS=(NAME HOST PORT USER KEY JUMP ADDR NOTE)

node_reset() { N_NAME=""; N_HOST=""; N_PORT="22"; N_USER="root"; N_KEY=""; N_JUMP=""; N_ADDR=""; N_NOTE=""; }
node_path() { printf '%s/%s.conf' "$NODE_DIR" "$1"; }
node_exists() { [[ $1 == local || -f $(node_path "$1") ]]; }
node_load() {
  node_reset
  if [[ $1 == local ]]; then N_NAME="local"; return 0; fi
  kv_load "$(node_path "$1")" N_ "${NODE_KEYS[@]}"
}
node_save() {
  mkdir -p "$NODE_DIR"
  kv_save "$(node_path "$N_NAME")" N_ "${NODE_KEYS[@]}"
  chmod 600 "$(node_path "$N_NAME")"
}
node_names() {
  local f
  for f in "$NODE_DIR"/*.conf; do
    [[ -f $f ]] || continue
    f=${f##*/}
    echo "${f%.conf}"
  done | sort
}
node_count() { node_names | grep -c . ; }

# 节点没有被链路或其他节点（跳板）引用时返回 0
node_unused() {
  local name=$1 f refs=""
  for f in "$CHAIN_DIR"/*.conf; do
    [[ -f $f ]] || continue
    if grep -E '^HOP_[0-9]+=' "$f" | cut -d= -f2- | tr ';' '\n' | cut -d'|' -f1 | grep -qxF "$name"; then
      refs+=" 链路 $(basename "$f" .conf)"
    fi
  done
  for f in "$NODE_DIR"/*.conf; do
    [[ -f $f ]] || continue
    if [[ $(kv_get "$f" JUMP) == "$name" ]]; then refs+=" 节点 $(basename "$f" .conf)(跳板)"; fi
  done
  [[ -z $refs ]] && return 0
  err "节点 $name 仍被使用:$refs（先删除相关链路/改掉跳板；确需删除可加 --force）"
  return 1
}
node_label() {
  if [[ $N_NAME == local ]]; then echo "本机"; return 0; fi
  printf '%s@%s:%s%s%s' "$N_USER" "$N_HOST" "$N_PORT" "${N_JUMP:+ 经跳板 $N_JUMP}" "${N_NOTE:+  · $N_NOTE}"
}

ensure_ssh_client() {
  has ssh && return 0
  case $(pkg_mgr) in
    apt-get) ensure_cmd ssh openssh-client ;;
    dnf|yum) ensure_cmd ssh openssh-clients ;;
    apk) ensure_cmd ssh openssh-client ;;
    pacman) ensure_cmd ssh openssh ;;
    *) has ssh ;;
  esac || { err "缺少 ssh 客户端"; return 1; }
}

ensure_nxr_key() {
  [[ -f $NXR_KEY ]] && return 0
  ensure_ssh_client || return 1
  mkdir -p "$SSH_DIR" && chmod 700 "$SSH_DIR"
  ssh-keygen -q -t ed25519 -N '' -C "nxr@$(hostname 2>/dev/null || echo host)" -f "$NXR_KEY" || { err "生成密钥失败"; return 1; }
  ok "已生成 nxr 专用密钥: $NXR_KEY"
}

SSH_HKC=""
ssh_base_opts() {
  if [[ -z $SSH_HKC ]]; then
    local v
    v=$(ssh -V 2>&1 | grep -oE 'OpenSSH_[0-9]+\.[0-9]+' | head -1 | cut -d_ -f2)
    if [[ -n $v ]] && awk -v v="$v" 'BEGIN { exit !(v + 0 >= 7.6) }'; then SSH_HKC="accept-new"; else SSH_HKC="no"; fi
  fi
  SSH_BASE=(-o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=4
            -o "StrictHostKeyChecking=$SSH_HKC" -o "UserKnownHostsFile=$KNOWN_HOSTS" -o LogLevel=ERROR)
}

# 生成访问节点的 ssh 命令（不含远程命令）到数组 SSH_CMD
node_ssh_cmd() {
  local name=$1 proxy
  node_load "$name" || { err "节点不存在: $name"; return 1; }
  ensure_ssh_client || return 1
  ssh_base_opts
  # 主机密钥按节点名记录：不同跳板后面的节点可能共用同一个内网 IP
  SSH_CMD=(ssh "${SSH_BASE[@]}" -o "HostKeyAlias=nxr-$name" -p "$N_PORT")
  if [[ -n $N_KEY ]]; then SSH_CMD+=(-i "$N_KEY" -o IdentitiesOnly=yes); fi
  if [[ -n $N_JUMP ]]; then
    proxy=$(node_jump_proxy "$N_JUMP") || return 1
    SSH_CMD+=(-o "ProxyCommand=$proxy")
  fi
  SSH_CMD+=("$N_USER@$N_HOST")
}

# 经跳板节点连接时使用的 ProxyCommand
node_jump_proxy() {
  local jump=$1 jf jh jp ju jk proxy
  jf=$(node_path "$jump")
  [[ -f $jf ]] || { err "跳板节点不存在: $jump"; return 1; }
  jh=$(kv_get "$jf" HOST); jp=$(kv_get "$jf" PORT); ju=$(kv_get "$jf" USER); jk=$(kv_get "$jf" KEY)
  proxy="ssh ${SSH_BASE[*]} -o HostKeyAlias=nxr-$jump -p ${jp:-22}"
  if [[ -n $jk ]]; then proxy+=" -i $(printf '%q' "$jk") -o IdentitiesOnly=yes"; fi
  proxy+=" -W [%h]:%p ${ju:-root}@$jh"
  echo "$proxy"
}

# node_exec 节点 解释器(bash|sh) 脚本：以 root 身份在节点执行，脚本经 stdin 传入
node_exec() {
  local name=$1 interp=$2 script=$3 wrap
  if [[ $name == local ]]; then
    "$interp" -s <<<"$script"
    return
  fi
  node_ssh_cmd "$name" || return 255
  wrap="$interp -s"
  if [[ $N_USER != root ]]; then wrap="sudo -n $interp -s"; fi
  "${SSH_CMD[@]}" "$wrap" <<<"$script"
}

# node_nxr 节点 参数...：在节点上调用 nxr
node_nxr() {
  local name=$1
  shift
  node_exec "$name" bash "$REMOTE_NXR $(printf '%q ' "$@") </dev/null"
}

# node_push 节点 本地文件 远程路径 [权限]：远端核对 cksum 和大小，传输不完整不会覆盖原文件
node_push() {
  local name=$1 src=$2 dst=$3 mode=${4:-755} pre="" sum
  node_ssh_cmd "$name" || return 1
  if [[ $N_USER != root ]]; then pre="sudo -n "; fi
  sum=$(cksum < "$src" | awk '{print $1, $2}')
  "${SSH_CMD[@]}" "${pre}sh -c 't=\"$dst.nxrtmp\"; cat > \"\$t\" && [ \"\$(cksum < \"\$t\" | awk \"{print \\\$1, \\\$2}\")\" = \"$sum\" ] && chmod $mode \"\$t\" && mv -f \"\$t\" \"$dst\" || { rm -f \"\$t\"; exit 1; }'" < "$src"
}

# 交互式终端（打开节点上的 nxr 面板等）
node_tty() {
  local name=$1
  shift
  node_ssh_cmd "$name" || return 1
  local pre=""
  if [[ $N_USER != root ]]; then pre="sudo "; fi
  "${SSH_CMD[@]}" -t "${pre}$*"
}

NODE_CHECK_SCRIPT='a=$(uname -m)
b=no; command -v bash >/dev/null 2>&1 && b=yes
n=none; [ -x /usr/local/bin/nxr ] && n=$(/usr/local/bin/nxr version --raw 2>/dev/null </dev/null)
s=none; [ -f /usr/local/bin/nxr ] && s=$(cksum < /usr/local/bin/nxr | cut -d" " -f1)
r=none; [ -x /usr/local/bin/realm ] && r=$(/usr/local/bin/realm --version 2>/dev/null </dev/null | head -n1)
echo "NXRCHK|$a|$b|${n:-none}|${r:-none}|$s"'

NODE_BASH_SCRIPT='if command -v apk >/dev/null 2>&1; then apk add --no-cache bash
elif command -v apt-get >/dev/null 2>&1; then DEBIAN_FRONTEND=noninteractive apt-get install -y bash
elif command -v dnf >/dev/null 2>&1; then dnf install -y bash
elif command -v yum >/dev/null 2>&1; then yum install -y bash
fi >/dev/null 2>&1'

# 节点上安装 realm：先让节点自己在线下载，失败则由本机推送（适合禁海外的 IX 入口机）
node_ensure_realm() {
  local name=$1 arch=$2 out rc tag triple src
  info "[$name] 节点未安装 realm，尝试在节点上在线安装"
  out=$(node_nxr "$name" install-realm --yes 2>&1); rc=$?
  if [[ $rc -eq 0 ]]; then ok "[$name] realm 在线安装成功"; return 0; fi
  warn "[$name] 节点无法在线下载 realm，改为从本机推送"
  tag=$(realm_version)
  if [[ -n $tag ]]; then tag="v$tag"; else tag=$(realm_latest_tag); fi
  triple=$(realm_triple "$arch" musl) || { err "[$name] 不支持的架构: $arch"; return 1; }
  src=$(realm_cache_get "$tag" "$triple" 2>/dev/null) || src=""
  if [[ -z $src && $arch == "$(uname -m)" && -x $REALM_BIN ]]; then src=$REALM_BIN; fi
  if [[ -z $src ]]; then
    err "[$name] 本机也无法获得 $arch 架构的 realm。请把 realm 压缩包上传到节点后执行: nxr install-realm --file <文件>"
    return 1
  fi
  node_push "$name" "$src" /usr/local/bin/realm 755 || { err "[$name] 推送 realm 失败"; return 1; }
  if ! node_exec "$name" sh '/usr/local/bin/realm --version' >/dev/null 2>&1; then
    err "[$name] 推送的 realm 无法运行"
    return 1
  fi
  ok "[$name] 已从本机推送 realm（$tag $triple）"
}

# 确保节点可用：SSH 连通、bash、nxr 版本一致、realm 已安装
node_prepare() {
  local name=$1 out arch hasbash nver rver nsum lver
  if [[ $name == local ]]; then
    self_install || true
    ensure_realm || return 1
    svc_setup >/dev/null || return 1
    return 0
  fi
  info "[$name] 检查连接..."
  out=$(node_exec "$name" sh "$NODE_CHECK_SCRIPT" 2>&1)
  if [[ $out != *NXRCHK\|* ]]; then
    if [[ $out == *sudo:* ]]; then
      err "[$name] sudo 需要密码：请为该用户配置免密 sudo，或改用 root 登录"
    else
      err "[$name] SSH 连接失败: $(tail -n 2 <<<"$out" | tr '\n' ' ')"
    fi
    return 1
  fi
  out=$(grep '^NXRCHK|' <<<"$out" | tail -n1)
  IFS='|' read -r _ arch hasbash nver rver nsum <<<"$out"
  if [[ $hasbash != yes ]]; then
    info "[$name] 安装 bash"
    node_exec "$name" sh "$NODE_BASH_SCRIPT" >/dev/null 2>&1
    node_exec "$name" sh 'command -v bash' >/dev/null 2>&1 || { err "[$name] 节点缺少 bash 且自动安装失败"; return 1; }
  fi
  [[ -f $NXR_BIN ]] || self_install
  [[ -f $NXR_BIN ]] || { err "本机未安装 nxr（$NXR_BIN），无法同步到节点"; return 1; }
  if [[ $nsum != "$(cksum < "$NXR_BIN" | cut -d' ' -f1)" ]]; then
    lver=$(grep -m1 '^NXR_VERSION=' "$NXR_BIN" | cut -d'"' -f2)
    if [[ $nver != none ]] && ver_gt "$nver" "$lver"; then
      warn "[$name] 节点上的 nxr $nver 比本机 $lver 新，未覆盖（建议先在本机执行 nxr update）"
    else
      info "[$name] 同步 nxr $lver（节点当前: $nver）"
      node_push "$name" "$NXR_BIN" "$REMOTE_NXR" 755 || { err "[$name] 推送 nxr 失败"; return 1; }
    fi
  fi
  node_nxr "$name" init --quiet >/dev/null 2>&1 || { err "[$name] 节点初始化失败（需要 systemd 或 OpenRC）"; return 1; }
  if [[ $rver == none ]]; then
    node_ensure_realm "$name" "$arch" || return 1
  fi
  ok "[$name] 就绪（$arch）"
}

node_test() {
  local name=$1 out s e
  s=$(now_us)
  out=$(node_exec "$name" sh "$NODE_CHECK_SCRIPT" 2>&1)
  e=$(now_us)
  if [[ $out == *NXRCHK\|* ]]; then
    local arch hasbash nver rver nsum
    IFS='|' read -r _ arch hasbash nver rver nsum <<<"$(grep '^NXRCHK|' <<<"$out" | tail -n1)"
    printf '  %s●%s %-14s SSH 正常 %4sms  架构 %-8s nxr %-8s realm %s\n' "$C_GRN" "$C_RST" "$name" \
      "$(( (e - s) / 1000 ))" "$arch" "$nver" "$(awk '{print $2}' <<<"$rver")"
    return 0
  fi
  printf '  %s●%s %-14s SSH 失败  %s\n' "$C_RED" "$C_RST" "$name" "$(tail -n 1 <<<"$out")"
  return 1
}

# 用密码登录一次，把 nxr 公钥写入节点（之后免密）
node_copy_key() {
  local name=$1 pub cmd pre=""
  ensure_nxr_key || return 1
  node_load "$name" || { err "节点不存在: $name"; return 1; }
  [[ -t 0 ]] || { err "安装公钥需要在交互终端中输入密码"; return 1; }
  pub=$(cat "$NXR_KEY.pub")
  ssh_base_opts
  local -a cmdline=(ssh -o ConnectTimeout=10 -o "StrictHostKeyChecking=$SSH_HKC" -o "UserKnownHostsFile=$KNOWN_HOSTS" -o LogLevel=ERROR
                    -o "HostKeyAlias=nxr-$name" -p "$N_PORT")
  if [[ -n $N_JUMP ]]; then
    local proxy
    proxy=$(node_jump_proxy "$N_JUMP") || return 1
    cmdline+=(-o "ProxyCommand=$proxy")
  fi
  # 原文件末尾没有换行时先补一个，否则公钥会接在上一行后面
  cmd="umask 077; mkdir -p ~/.ssh && touch ~/.ssh/authorized_keys && { grep -qxF '$pub' ~/.ssh/authorized_keys || { if [ -s ~/.ssh/authorized_keys ] && [ -n \"\$(tail -c 1 ~/.ssh/authorized_keys)\" ]; then echo >> ~/.ssh/authorized_keys; fi; echo '$pub' >> ~/.ssh/authorized_keys; }; } && echo NXR_KEY_OK"
  info "请输入 $N_USER@$N_HOST 的登录密码（仅本次使用，不会保存）"
  if "${cmdline[@]}" "$N_USER@$N_HOST" "$cmd" | grep -q NXR_KEY_OK; then
    N_KEY=$NXR_KEY
    node_save
    ok "[$name] 公钥已安装，之后免密登录"
    return 0
  fi
  err "[$name] 公钥安装失败"
  return 1
}

node_add_wizard() {
  local c names
  title "新增节点"
  echo "  说明：节点即链路中需要部署 realm 的机器（IX 入口、中转、落地等），通过 SSH 管理。"
  echo
  node_reset
  while :; do
    ask N_NAME "节点名称（字母/数字/-/_，例如 ix-gz、hk-exit）" "" || return 1
    if ! is_name "$N_NAME" || [[ $N_NAME == local ]]; then err "名称无效"; continue; fi
    if node_exists "$N_NAME"; then err "节点已存在"; continue; fi
    break
  done
  while :; do ask N_HOST "SSH 地址（IP 或域名）" "" || return 1; is_host "$N_HOST" && break; err "地址无效"; done
  while :; do ask N_PORT "SSH 端口" "22" || return 1; is_port "$N_PORT" && break; err "端口无效"; done
  while :; do ask N_USER "SSH 用户（非 root 需免密 sudo）" "root" || return 1; [[ $N_USER =~ ^[a-z_][a-z0-9_.-]{0,31}$ ]] && break; err "用户名无效"; done
  echo
  echo "  认证方式："
  echo "    1) nxr 专用密钥（推荐：自动生成，首次输入一次密码安装公钥）"
  echo "    2) 指定已有私钥文件"
  echo "    3) 使用本机 ~/.ssh 下的默认密钥"
  ask c "请选择" "1" || return 1
  case $c in
    2) while :; do ask N_KEY "私钥路径" "/root/.ssh/id_ed25519" || return 1; [[ -f $N_KEY && $N_KEY != *' '* ]] && break; err "文件不存在或路径含空格"; done ;;
    3) N_KEY="" ;;
    *) ensure_nxr_key || return 1; N_KEY=$NXR_KEY ;;
  esac
  mapfile -t names < <(node_names)
  if [[ ${#names[@]} -gt 0 ]]; then
    echo "  已有节点: ${names[*]}"
    while :; do
      ask N_JUMP "跳板节点（本机无法直连该节点时经由其 SSH，回车不使用）" "" || return 1
      [[ -z $N_JUMP ]] && break
      [[ -f $(node_path "$N_JUMP") ]] && break
      err "节点不存在: $N_JUMP"
    done
  fi
  ask N_ADDR "上一跳连接该节点使用的地址（回车同 SSH 地址；走 IX/内网时填内网 IP）" "$N_HOST" || return 1
  is_host "$N_ADDR" || N_ADDR=$N_HOST
  ask N_NOTE "备注（可选，例如 IX 入口 / 香港落地）" "" || return 1
  is_text "$N_NOTE" || N_NOTE=""
  node_save
  ok "节点 $N_NAME 已保存"
  if node_test "$N_NAME"; then return 0; fi
  if [[ $N_KEY == "$NXR_KEY" ]] && confirm "免密登录未就绪，现在用密码安装公钥?" Y; then
    node_copy_key "$N_NAME" && node_test "$N_NAME"
  fi
  return 0
}

# pick_node 变量名 [默认]：交互选择节点（可现场新增）
pick_node() {
  local __v=$1 def=${2:-} names=() n i c picked=""
  [[ -t 0 ]] || { err "选择节点需要在交互终端中进行"; return 1; }
  mapfile -t names < <(node_names)
  echo "    0) 本机 (local)"
  i=1
  for n in "${names[@]}"; do
    node_load "$n"
    printf '    %d) %-14s %s\n' "$i" "$n" "$(node_label)"
    i=$((i + 1))
  done
  echo "    a) 新增节点"
  while :; do
    ask c "选择节点" "$def" || return 1
    case $c in
      a|A)
        if node_add_wizard; then picked=$N_NAME; break; fi ;;
      0|local) picked=local; break ;;
      *)
        if [[ $c =~ ^[0-9]+$ ]] && (( c >= 1 && c <= ${#names[@]} )); then picked=${names[c-1]}; break; fi
        if [[ -n $c && -f $(node_path "$c") ]]; then picked=$c; break; fi
        err "无效选择" ;;
    esac
  done
  printf -v "$__v" '%s' "$picked"
}

# ================================================================== 链路（多跳 · 多 IX · 多出口）
# 链路记录 /etc/nxr/chains/<ID>.conf：
#   HOP_i         第 i 跳的成员，多个用 ; 分隔，每个为 节点|端口|上一跳连接它的地址|出站网卡|出站源IP
#   TARGET        出口地址，逗号分隔；写成 节点=地址 的只给该节点使用
#   MODE          一跳有多台节点时上一跳的分流方式；TARGET_MODE 一台节点有多个出口时的分流方式
chain_ids() {
  local f
  for f in "$CHAIN_DIR"/*.conf; do
    [[ -f $f ]] || continue
    f=${f##*/}
    echo "${f%.conf}"
  done | sort -V
}
chain_count() { chain_ids | grep -c . ; }
chain_next_id() {
  local i=1
  while [[ -f $CHAIN_DIR/c$i.conf ]]; do i=$((i + 1)); done
  echo "c$i"
}
chain_load() {
  local f k v
  declare -gA CH=()
  f="$CHAIN_DIR/$1.conf"
  [[ -f $f ]] || return 1
  while IFS='=' read -r k v || [[ -n $k ]]; do
    if [[ $k =~ ^[A-Z0-9_]+$ ]]; then CH[$k]=$v; fi
  done < "$f"
  [[ -n ${CH[MODE]:-} ]] || CH[MODE]=failover
  [[ -n ${CH[TARGET_MODE]:-} ]] || CH[TARGET_MODE]=failover
  return 0
}

hop_role() { if [[ $1 -eq 1 ]]; then echo "前置"; else echo "IX/中转"; fi; }

transport_label() {
  case $1 in tls) echo "TLS";; ws) echo "WebSocket";; wss) echo "WebSocket+TLS";; *) echo "不加密";; esac
}

mode_label() {
  case $1 in roundrobin) echo "轮询负载均衡";; iphash) echo "按来源IP分流";; *) echo "主备切换";; esac
}
valid_mode() { [[ $1 == failover || $1 == roundrobin || $1 == iphash ]]; }

pick_mode() { # pick_mode 变量名 "说明"
  local __v=$1 c
  echo "  $2："
  echo "    1) 主备切换（平时只走第一个，故障自动切到下一个，恢复后切回）"
  echo "    2) 轮询负载均衡（连接轮流分配，故障成员自动摘除）"
  echo "    3) 按来源 IP 分流（同一客户端固定走同一个，故障成员自动摘除）"
  ask c "请选择" "1" || return 1
  case $c in 2) printf -v "$__v" roundrobin ;; 3) printf -v "$__v" iphash ;; *) printf -v "$__v" failover ;; esac
}

# 生成跳间传输参数：TL_LISTEN / TL_REMOTE
transport_build() {
  local mode=$1 sni=$2 host=$3 path=$4
  TL_LISTEN=""; TL_REMOTE=""
  case $mode in
    tls) TL_LISTEN="tls;servername=$sni"; TL_REMOTE="tls;sni=$sni;insecure" ;;
    ws) TL_LISTEN="ws;host=$host;path=$path"; TL_REMOTE="ws;host=$host;path=$path" ;;
    wss) TL_LISTEN="ws;host=$host;path=$path;tls;servername=$sni"; TL_REMOTE="ws;host=$host;path=$path;tls;sni=$sni;insecure" ;;
  esac
}

ask_transport() { # ask_transport 变量名：选择跳间传输，同时设置 TL_LISTEN / TL_REMOTE
  local __v=$1 c m=none sni="www.bing.com" host="www.bing.com" path
  TL_LISTEN=""; TL_REMOTE=""
  echo "  跳间传输加密（只作用于 TCP；UDP 仍明文转发）："
  echo "    1) 不加密（默认，适合承载 SS/VLESS 等已加密协议，性能最好）"
  echo "    2) TLS     3) WebSocket     4) WebSocket + TLS"
  ask c "请选择" "1" || return 1
  case $c in 2) m=tls ;; 3) m=ws ;; 4) m=wss ;; esac
  if [[ $m != none ]]; then
    path="/$(tr -dc 'a-z0-9' </dev/urandom 2>/dev/null | head -c 8)"
    [[ $path == / ]] && path="/nxr"
    if [[ $m != ws ]]; then ask sni "TLS SNI/证书域名" "$sni" || return 1; fi
    if [[ $m != tls ]]; then ask host "WebSocket Host" "$host" || return 1; ask path "WebSocket 路径" "$path" || return 1; fi
    transport_build "$m" "$sni" "$host" "$path"
    if ! is_transport "$TL_LISTEN" || ! is_transport "$TL_REMOTE"; then err "传输参数含非法字符"; return 1; fi
  fi
  printf -v "$__v" '%s' "$m"
}

show_node_ifaces() {
  local name=$1 out
  out=$(node_nxr "$name" ifaces 2>/dev/null)
  [[ -z $out ]] && return 1
  echo "    [$name] 网卡地址："
  awk '{printf "      %-10s %s\n", $1, $2}' <<<"$out"
}

# 解析一跳的成员 → M_NODE M_PORT M_ADDR M_IFACE M_THROUGH
tier_parse() {
  local m a b c d e
  local -a ms
  M_NODE=(); M_PORT=(); M_ADDR=(); M_IFACE=(); M_THROUGH=()
  IFS=';' read -ra ms <<<"$1"
  for m in "${ms[@]}"; do
    [[ -z $m ]] && continue
    IFS='|' read -r a b c d e <<<"$m"
    M_NODE+=("$a"); M_PORT+=("$b"); M_ADDR+=("$c"); M_IFACE+=("$d"); M_THROUGH+=("$e")
  done
}

# 上一跳连接这一跳全部成员的地址池（逗号分隔）
tier_pool() {
  local k out=""
  tier_parse "$1"
  for k in "${!M_NODE[@]}"; do out+="${out:+,}$(join_hostport "${M_ADDR[k]}" "${M_PORT[k]}")"; done
  echo "$out"
}

tier_str() {
  local k out=""
  tier_parse "$1"
  for k in "${!M_NODE[@]}"; do out+="${out:+ | }${M_NODE[k]}:${M_PORT[k]}"; done
  if [[ ${#M_NODE[@]} -gt 1 ]]; then out="[$out]"; fi
  echo "$out"
}

# 某台最后一跳节点使用的出口地址（逗号分隔）
targets_for() {
  local node=$1 x out=""
  local -a xs
  IFS=, read -ra xs <<<"$2"
  for x in "${xs[@]}"; do
    [[ -z $x ]] && continue
    if [[ $x == *=* ]]; then
      if [[ ${x%%=*} == "$node" ]]; then out+="${out:+,}${x#*=}"; fi
    else
      out+="${out:+,}$x"
    fi
  done
  echo "$out"
}

# 只保留通用出口地址和给定节点的专属地址
targets_keep() {
  local tg=$1 x out=""
  local -a xs
  shift
  IFS=, read -ra xs <<<"$tg"
  for x in "${xs[@]}"; do
    if [[ $x == *=* && " $* " != *" ${x%%=*} "* ]]; then continue; fi
    out+="${out:+,}$x"
  done
  echo "$out"
}

targets_str() {
  local x out=""
  local -a xs
  IFS=, read -ra xs <<<"$1"
  for x in "${xs[@]}"; do out+="${out:+ | }${x/=/→}"; done
  if [[ ${#xs[@]} -gt 1 ]]; then out="[$out]"; fi
  echo "$out"
}

# 把地址池和分流方式转成 nxr add 参数，追加到调用者的 args 数组
pool_args() {
  local addrs=$1 mode=$2
  args+=(--remote "${addrs%%,*}")
  if [[ $addrs == *,* ]]; then
    case $mode in
      roundrobin|iphash) args+=(--extra "${addrs#*,}" --balance "$mode" --health) ;;
      *) args+=(--backup "${addrs#*,}") ;;
    esac
  fi
}

# 当前 CH 的分流方式说明（仅在有多台节点/多个出口时显示）
chain_mode_desc() {
  local i n=${CH[HOPS]} s="" multi=0 tm=0 x
  local -a last
  for (( i = 2; i <= n; i++ )); do
    if [[ ${CH[HOP_$i]} == *';'* ]]; then multi=1; fi
  done
  tier_parse "${CH[HOP_$n]}"
  last=("${M_NODE[@]}")
  for x in "${last[@]}"; do
    if [[ $(targets_for "$x" "${CH[TARGET]}") == *,* ]]; then tm=1; fi
  done
  if [[ $multi == 1 ]]; then s+="  多IX：$(mode_label "${CH[MODE]}")"; fi
  if [[ $tm == 1 ]]; then s+="  多出口：$(mode_label "${CH[TARGET_MODE]}")"; fi
  echo "$s"
}

# 交互多选节点，结果写入数组 PICKED
pick_nodes() {
  local prompt=$1 allow_local=${2:-0} n i c x bad
  local -a names uniq
  local -A seen
  [[ -t 0 ]] || { err "选择节点需要在交互终端中进行"; return 1; }
  mapfile -t names < <(node_names)
  if [[ $allow_local == 1 ]]; then echo "    0) 本机 (local)"; fi
  i=1
  for n in "${names[@]}"; do
    node_load "$n"
    printf '    %d) %-14s %s\n' "$i" "$n" "$(node_label)"
    i=$((i + 1))
  done
  echo "    a) 新增节点"
  while :; do
    ask c "$prompt（序号，多台用空格分隔）" "" || return 1
    if [[ $c == a || $c == A ]]; then
      if node_add_wizard; then
        names+=("$N_NAME")
        printf '    %d) %-14s（新增）\n' "${#names[@]}" "$N_NAME"
      fi
      continue
    fi
    PICKED=(); bad=0
    for x in $c; do
      if [[ $x == 0 && $allow_local == 1 ]] || [[ $x == local && $allow_local == 1 ]]; then PICKED+=(local)
      elif [[ $x =~ ^[0-9]+$ ]] && (( x >= 1 && x <= ${#names[@]} )); then PICKED+=("${names[x-1]}")
      elif [[ -f $(node_path "$x") ]]; then PICKED+=("$x")
      else err "无效选择: $x"; bad=1
      fi
    done
    [[ $bad == 0 && ${#PICKED[@]} -gt 0 ]] || continue
    uniq=(); seen=()
    for x in "${PICKED[@]}"; do
      [[ -n ${seen[$x]+x} ]] && continue
      seen[$x]=1; uniq+=("$x")
    done
    PICKED=("${uniq[@]}")
    return 0
  done
}

# 询问某台节点在这一跳的端口和上一跳连接地址 → MEMBER_SPEC
ask_member() {
  local node=$1 i=$2 def port addr out
  MEMBER_SPEC=""
  def=$(node_nxr "$node" random-port 2>/dev/null | tail -n1)
  while :; do
    ask port "[$node] 监听端口" "$def" || return 1
    if ! is_port "$port"; then err "端口无效"; continue; fi
    if [[ $CHAIN_USED == *" $node:$port "* ]]; then err "[$node] 端口 $port 已被这条链路的其他跳使用"; continue; fi
    if out=$(node_nxr "$node" port-check "$port" 2>&1); then break; fi
    err "[$node] $out"
  done
  addr=""
  if [[ $i -gt 1 ]]; then
    node_load "$node"
    def=${N_ADDR:-$N_HOST}
    if [[ $node == local ]]; then def=$(public_ipv4 2>/dev/null); fi
    while :; do
      ask addr "[$node] 上一跳连接它使用的地址（公网 IP / IX 内网 IP / 域名）" "$def" || return 1
      is_host "$addr" && break
      err "地址无效"
    done
  fi
  MEMBER_SPEC="$node|$port|$addr||"
  CHAIN_USED+="$node:$port "
}

# 为成员设置出站网卡/源 IP → MEMBER_SPEC
ask_member_out() {
  local node port addr iface through
  IFS='|' read -r node port addr iface through <<<"$1"
  show_node_ifaces "$node"
  ask iface "[$node] 出站网卡（回车自动）" "" || return 1
  if [[ -n $iface ]] && ! is_iface "$iface"; then err "网卡名无效，已忽略"; iface=""; fi
  ask through "[$node] 出站源 IP（回车自动）" "" || return 1
  if [[ -n $through ]] && ! is_ip "$through"; then err "IP 无效，已忽略"; through=""; fi
  MEMBER_SPEC="$node|$port|$addr|$iface|$through"
}

chain_preview() { # 显示 H_SPEC / C_TARGETS 描述的链路
  local cid=$1 cname=$2 proto=$3 tmode=$4 n=$5 i k
  echo
  hr
  printf '  链路 %s「%s」  协议 %s  跳间传输 %s\n' "$cid" "$cname" "$(proto_label "$proto")" "$(transport_label "$tmode")"
  for (( i = 1; i <= n; i++ )); do
    tier_parse "${H_SPEC[i]}"
    for k in "${!M_NODE[@]}"; do
      if [[ $i -eq 1 ]]; then
        printf '    第1跳 [%s] 监听 :%s\n' "${M_NODE[k]}" "${M_PORT[k]}"
      else
        printf '    第%d跳 [%s] %s\n' "$i" "${M_NODE[k]}" "$(join_hostport "${M_ADDR[k]}" "${M_PORT[k]}")"
      fi
      if [[ -n ${M_IFACE[k]}${M_THROUGH[k]} ]]; then printf '          出站 %s %s\n' "${M_IFACE[k]}" "${M_THROUGH[k]}"; fi
      if [[ $i -eq $n ]]; then printf '          → 出口 %s\n' "$(targets_for "${M_NODE[k]}" "$C_TARGETS" | sed 's/,/ | /g')"; fi
    done
  done
  printf '    多 IX 分流：%s    多出口分流：%s\n' "$(mode_label "$C_MODE")" "$(mode_label "$C_TMODE")"
  hr
}

chain_wizard() {
  local cid cname proto c n k x node tmode="none" out common per t multi=0 tmulti=0 okall
  local -a H_SPEC=() members=() last=() tl=()
  CHAIN_USED=" "; C_MODE=failover; C_TMODE=failover; C_TARGETS=""
  title "创建转发链路（前置 → IX → 出口，支持多 IX / 多出口）"
  cat <<'EOF'
  链路由若干"跳"组成，每一跳是一台或几台运行 realm 的机器，最后一跳把流量送到出口（落地服务）。
  典型 IX 链路：客户端 → 前置:11111 → IX 入口:22222 →(IX/内网)→ 出口 192.168.x.x:33333

  · 第 1 跳是客户端连接的前置机；之后每一跳可以选多台 IX 共同承担（主备或负载均衡）
  · 出口可以填多台配置相同的落地（主备或负载均衡），各 IX 访问出口的地址也可以不同
  · 远程节点通过 SSH 自动下发 nxr / realm 和规则；一次开多条线路请用「链路管理 → 批量开线路」
EOF
  hr
  ensure_ssh_client >/dev/null 2>&1 || true
  self_install || true
  cid=$(chain_next_id)
  while :; do ask cname "链路名称" "$cid" || return 1; is_text "$cname" && [[ ${#cname} -le 58 ]] && break; err "名称无效（最多 58 个字符，不能含 |）"; done
  echo "  转发协议：1) TCP+UDP（默认）  2) 仅 TCP  3) 仅 UDP"
  ask c "请选择" "1" || return 1
  case $c in 2) proto=tcp ;; 3) proto=udp ;; *) proto=both ;; esac

  echo
  printf '  %s第 1 跳 · 前置（客户端连接这一跳）%s\n' "$C_BLD" "$C_RST"
  while :; do
    pick_node node "0" || return 1
    node_prepare "$node" && break
    confirm "节点准备失败，重新选择?" Y || return 1
  done
  ask_member "$node" 1 || return 1
  if confirm "为前置指定出站网卡/源 IP?（一般回车跳过）" N; then ask_member_out "$MEMBER_SPEC" || return 1; fi
  H_SPEC[1]=$MEMBER_SPEC
  n=1
  while :; do
    if [[ $n -eq 1 ]]; then
      confirm "添加第 2 跳（IX/中转）?（选否则前置直接转发到出口）" Y || break
    else
      confirm "继续添加第 $((n + 1)) 跳?" N || break
    fi
    n=$((n + 1))
    echo
    printf '  %s第 %d 跳 · IX/中转（可多选，多台共同承担这一跳）%s\n' "$C_BLD" "$n" "$C_RST"
    while :; do
      pick_nodes "选择节点" 1 || return 1
      okall=1
      for x in "${PICKED[@]}"; do node_prepare "$x" || okall=0; done
      [[ $okall == 1 ]] && break
      confirm "有节点准备失败，重新选择?" Y || return 1
    done
    members=()
    for x in "${PICKED[@]}"; do ask_member "$x" "$n" || return 1; members+=("$MEMBER_SPEC"); done
    if confirm "为这一跳的节点指定出站网卡/源 IP?（多网卡 IX 机走内网时用，一般回车跳过）" N; then
      for k in "${!members[@]}"; do ask_member_out "${members[k]}" || return 1; members[k]=$MEMBER_SPEC; done
    fi
    H_SPEC[n]=$(IFS=';'; echo "${members[*]}")
    if [[ ${#members[@]} -gt 1 ]]; then multi=1; fi
  done
  if [[ $multi == 1 ]]; then echo; pick_mode C_MODE "一跳有多台节点时，上一跳如何分配流量" || return 1; fi

  echo
  tier_parse "${H_SPEC[n]}"
  last=("${M_NODE[@]}")
  printf '  %s出口（落地）%s：由最后一跳 %s 转发过去\n' "$C_BLD" "$C_RST" "${last[*]}"
  echo "  · 填落地机上代理服务的 IP:端口，IPv6 写成 [地址]:端口；与 IX 在同一内网时填内网 IP"
  echo "  · 多台配置相同的落地用逗号分隔，例如 10.0.0.1:33333,10.0.0.2:33333"
  show_node_ifaces "${last[0]}"
  while :; do
    ask common "出口地址" "" || return 1
    common=${common// /}
    [[ -n $common ]] && valid_hostport_list "$common" && break
    err "格式无效"
  done
  C_TARGETS=$common
  if [[ ${#last[@]} -gt 1 ]] && confirm "各台节点访问出口的地址不同?（例如各自走自己的内网）" N; then
    C_TARGETS=""
    for x in "${last[@]}"; do
      while :; do
        ask per "[$x] 访问出口使用的地址" "$common" || return 1
        per=${per// /}
        valid_hostport_list "$per" && break
        err "格式无效"
      done
      IFS=, read -ra tl <<<"$per"
      for t in "${tl[@]}"; do C_TARGETS+="${C_TARGETS:+,}$x=$t"; done
    done
  fi
  for x in "${last[@]}"; do
    if [[ $(targets_for "$x" "$C_TARGETS") == *,* ]]; then tmulti=1; fi
  done
  if [[ $tmulti == 1 ]]; then echo; pick_mode C_TMODE "一台节点对应多个出口时如何分配流量" || return 1; fi
  info "探测出口连通性..."
  for x in "${last[@]}"; do
    IFS=, read -ra tl <<<"$(targets_for "$x" "$C_TARGETS")"
    for t in "${tl[@]}"; do
      split_hostport "$t" || continue
      out=$(node_nxr "$x" probe --raw "$HP_HOST" "$HP_PORT" 2>/dev/null | tail -n1)
      if [[ $out == ok* ]]; then ok "[$x] → $t 可达，${out#ok } ms"; else warn "[$x] → $t 暂不可达（服务未启动或仅 UDP 时可忽略）"; fi
    done
  done

  TL_LISTEN=""; TL_REMOTE=""
  if [[ $n -gt 1 && $proto != udp ]]; then echo; ask_transport tmode || return 1; fi
  C_ACL=0
  if [[ $n -gt 1 ]] && confirm "IX/中转跳只接受上一跳的连接（来源 IP 白名单，防止端口被扫描盗用）?" Y; then C_ACL=1; fi
  chain_preview "$cid" "$cname" "$proto" "$tmode" "$n"
  confirm "确认部署这条链路?" Y || return 1
  chain_deploy "$cid" "$cname" "$proto" "$tmode" "$n"
}

chain_rollback() { # chain_rollback 链路ID 节点|端口...：全部清理干净返回 0
  local cid=$1 x left=0
  shift
  [[ $# -gt 0 ]] || return 0
  confirm "回滚已部署的部分?" Y || return 1
  for x in "$@"; do
    if node_nxr "${x%%|*}" del "${x#*|}" --chain "$cid" --yes >/dev/null 2>&1; then
      info "[${x%%|*}] 已回滚 :${x#*|}"
    else
      warn "[${x%%|*}] 回滚 :${x#*|} 失败"
      left=1
    fi
  done
  return "$left"
}

# 部署失败：回滚成功则删除记录，否则保留记录供 nxr chain del 清理
chain_fail() { # chain_fail 链路ID 节点|端口...
  local cid=$1
  shift
  if chain_rollback "$cid" "$@"; then
    rm -f "$CHAIN_DIR/$cid.conf"
  else
    sed -i 's/^STATE=.*/STATE=partial/' "$CHAIN_DIR/$cid.conf" 2>/dev/null
    warn "链路 $cid 还有未清理的规则，记录已保留，可稍后执行: nxr chain del $cid"
  fi
}

chain_state_note() { # 链路记录的部署状态说明
  case ${CH[STATE]:-} in
    deploying) printf '%s（部署未完成）%s' "$C_YLW" "$C_RST" ;;
    partial) printf '%s（部署失败，待清理）%s' "$C_RED" "$C_RST" ;;
  esac
}

chain_save() { # chain_save 链路ID 名称 协议 传输 跳数 [状态]
  local cid=$1 cname=$2 proto=$3 tmode=$4 n=$5 state=${6:-} i
  {
    echo "ID=$cid"
    if [[ -n $state ]]; then echo "STATE=$state"; fi
    echo "NAME=$cname"
    echo "PROTO=$proto"
    echo "TRANSPORT=$tmode"
    echo "TL_LISTEN=$TL_LISTEN"
    echo "TL_REMOTE=$TL_REMOTE"
    echo "MODE=$C_MODE"
    echo "TARGET_MODE=$C_TMODE"
    echo "TARGET=$C_TARGETS"
    echo "ACL=${C_ACL:-1}"
    echo "HOPS=$n"
    echo "CREATED=$(date '+%F %T')"
    for (( i = 1; i <= n; i++ )); do echo "HOP_$i=${H_SPEC[i]}"; done
  } > "$CHAIN_DIR/$cid.conf"
}

# 客户端连接地址（第 1 跳每台成员一个）
chain_entry() {
  local k host out=""
  chain_load "$1" || return 1
  tier_parse "${CH[HOP_1]}"
  for k in "${!M_NODE[@]}"; do
    if [[ ${M_NODE[k]} == local ]]; then
      host=$(public_ipv4 2>/dev/null || echo "本机IP")
    else
      host=$(kv_get "$(node_path "${M_NODE[k]}")" HOST)
    fi
    out+="${out:+ / }$(join_hostport "$host" "${M_PORT[k]}")"
  done
  echo "$out"
}

# 从最后一跳往前部署，保证上游生效时下游已就绪；使用 H_SPEC / C_TARGETS / C_MODE / C_TMODE
chain_deploy() {
  local cid=$1 cname=$2 proto=$3 tmode=$4 n=$5 quiet=${6:-0} i k pool next_pool mode out rc multi=0
  local -a args deployed=() tn tp ti tt
  CHAIN_ENTRY=""
  # 只有第 1 跳看得到客户端 IP，之后各跳的来源都是上一跳机器
  if [[ $n -gt 1 && $C_TMODE == iphash ]]; then
    warn "按来源 IP 分流只在前置这一跳有效，IX 到出口改用轮询负载均衡"
    C_TMODE=roundrobin
  fi
  for (( i = 1; i <= n; i++ )); do
    if [[ ${H_SPEC[i]} == *';'* ]]; then multi=1; fi
    if [[ $i -eq $n ]]; then
      tier_parse "${H_SPEC[i]}"
      for k in "${M_NODE[@]}"; do [[ $(targets_for "$k" "$C_TARGETS") == *,* ]] && multi=1; done
    fi
  done
  if [[ $proto == udp && $multi == 1 ]]; then
    warn "仅 UDP 链路无法探测健康状态：主备不会自动切换，负载均衡也不会自动摘除故障成员"
  fi
  # 第 2 跳起只接受上一跳各节点的连接：网卡地址 + 公网出口地址
  local -A srcs=()
  local -a allow_of=()
  if [[ ${C_ACL:-1} == 1 ]]; then
    for (( i = 2; i <= n; i++ )); do
      tier_parse "${H_SPEC[i-1]}"
      allow_of[i]=""
      for k in "${M_NODE[@]}"; do
        if [[ -z ${srcs[$k]+x} ]]; then
          srcs[$k]=$(node_nxr "$k" src-ips 2>/dev/null | grep -E '^[0-9A-Fa-f.:]+$' | paste -sd, -)
        fi
        if [[ -n ${srcs[$k]} ]]; then allow_of[i]+="${allow_of[i]:+,}${srcs[$k]}"; fi
      done
      if [[ -n ${allow_of[i]} ]]; then
        info "第 $i 跳只接受来自上一跳的连接: ${allow_of[i]//,/ }"
      else
        warn "取不到第 $((i - 1)) 跳的地址，第 $i 跳不启用来源白名单"
      fi
    done
  fi
  chain_save "$cid" "$cname" "$proto" "$tmode" "$n" deploying
  for (( i = n; i >= 1; i-- )); do
    next_pool=""
    if [[ $i -lt $n ]]; then next_pool=$(tier_pool "${H_SPEC[i+1]}"); fi
    tier_parse "${H_SPEC[i]}"
    tn=("${M_NODE[@]}"); tp=("${M_PORT[@]}"); ti=("${M_IFACE[@]}"); tt=("${M_THROUGH[@]}")
    for k in "${!tn[@]}"; do
      if [[ $i -eq $n ]]; then
        pool=$(targets_for "${tn[k]}" "$C_TARGETS"); mode=$C_TMODE
      else
        pool=$next_pool; mode=$C_MODE
      fi
      if [[ $mode == iphash && $i -gt 1 ]]; then mode=roundrobin; fi
      if [[ -z $pool ]]; then
        err "[${tn[k]}] 没有可用的出口地址"
        chain_fail "$cid" "${deployed[@]}"
        return 1
      fi
      args=(add --port "${tp[k]}" --proto "$proto" --name "${cname:0:58}#$i" --chain "$cid" --role "$(hop_role "$i")" --yes)
      pool_args "$pool" "$mode"
      if [[ -n ${ti[k]} ]]; then args+=(--iface "${ti[k]}"); fi
      if [[ -n ${tt[k]} ]]; then args+=(--through "${tt[k]}"); fi
      if [[ -n $TL_LISTEN && $i -gt 1 ]]; then args+=(--listen-transport "$TL_LISTEN"); fi
      if [[ -n $TL_REMOTE && $i -lt $n ]]; then args+=(--remote-transport "$TL_REMOTE"); fi
      if [[ -n ${allow_of[i]:-} ]]; then args+=(--allow "${allow_of[i]}"); fi
      info "[${tn[k]}] 部署第 $i 跳 :${tp[k]} → ${pool//,/ | }"
      out=$(node_nxr "${tn[k]}" "${args[@]}" 2>&1); rc=$?
      if [[ -n $out ]]; then sed 's/^/      /' <<<"$out" >&2; fi
      if [[ $rc -ne 0 ]]; then
        err "第 $i 跳 ${tn[k]} 部署失败"
        # 失败的成员也要尝试清理：SSH 可能在远端已创建规则后才断开（del --chain 不会动别的链路的规则）
        chain_fail "$cid" "${deployed[@]}" "${tn[k]}|${tp[k]}"
        return 1
      fi
      deployed+=("${tn[k]}|${tp[k]}")
    done
  done
  chain_save "$cid" "$cname" "$proto" "$tmode" "$n"
  ok "链路 $cid 部署完成"
  chain_check "$cid"
  CHAIN_ENTRY=$(chain_entry "$cid")
  if [[ $quiet != 1 ]]; then
    printf '\n  %s客户端连接地址：%s%s\n' "$C_GRN$C_BLD" "$CHAIN_ENTRY" "$C_RST"
    echo "  （客户端使用出口落地服务的协议参数，只把服务器地址/端口改成上面的入口）"
  fi
  return 0
}

chain_state_label() { # 输出 "颜色 文字"
  case $1 in
    active) printf '%s运行%s' "$C_GRN" "$C_RST" ;;
    disabled) printf '%s停用%s' "$C_YLW" "$C_RST" ;;
    missing) printf '%s缺失%s' "$C_RED" "$C_RST" ;;
    unreachable) printf '%s失联%s' "$C_RED" "$C_RST" ;;
    *) printf '%s异常%s' "$C_RED" "$C_RST" ;;
  esac
}

chain_check() {
  local cid=$1 n i k out st pool next_pool probe x res ms okn bad=0
  local -a tn tp
  chain_load "$cid" || { err "链路不存在: $cid"; return 1; }
  n=${CH[HOPS]}
  printf '\n  链路 %s「%s」  %s  跳间传输 %s%s\n' "$cid" "${CH[NAME]}" "$(proto_label "${CH[PROTO]}")" \
    "$(transport_label "${CH[TRANSPORT]}")" "$(chain_mode_desc)"
  for (( i = 1; i <= n; i++ )); do
    next_pool=""
    if [[ $i -lt $n ]]; then next_pool=$(tier_pool "${CH[HOP_$((i + 1))]}"); fi
    tier_parse "${CH[HOP_$i]}"
    tn=("${M_NODE[@]}"); tp=("${M_PORT[@]}")
    for k in "${!tn[@]}"; do
      if [[ $i -eq $n ]]; then pool=$(targets_for "${tn[k]}" "${CH[TARGET]}"); else pool=$next_pool; fi
      # TCP 探测对仅 UDP 的链路没有意义
      probe=$pool
      if [[ ${CH[PROTO]} == udp ]]; then probe=""; fi
      out=$(node_nxr "${tn[k]}" pool-check "${tp[k]}" "$probe" 2>/dev/null)
      st=$(head -n1 <<<"$out")
      case $st in
        active|activating|failed|inactive|disabled|missing) ;;
        "") st=unreachable ;;
        *)
          # 节点上的 nxr 版本过旧，同步后重试
          node_prepare "${tn[k]}" >/dev/null 2>&1
          out=$(node_nxr "${tn[k]}" pool-check "${tp[k]}" "$probe" 2>/dev/null)
          st=$(head -n1 <<<"$out")
          [[ -n $st ]] || st=unreachable ;;
      esac
      printf '  [%d] %-14s :%-6s %s\n' "$i" "${tn[k]}" "${tp[k]}" "$(chain_state_label "$st")"
      if [[ -z $probe ]]; then
        for x in ${pool//,/ }; do printf '        → %-30s %s仅 UDP，不做探测%s\n' "$x" "$C_GRY" "$C_RST"; done
        if [[ $st != active ]]; then bad=1; fi
        continue
      fi
      okn=0
      while read -r x res ms; do
        [[ -z $x ]] && continue
        if [[ $res == ok ]]; then
          okn=$((okn + 1))
          printf '        → %-30s %s可达 %sms%s\n' "$x" "$C_GRN" "$ms" "$C_RST"
        else
          printf '        → %-30s %s不可达%s\n' "$x" "$C_RED" "$C_RST"
        fi
      done < <(tail -n +2 <<<"$out")
      if [[ $st != active || $okn -eq 0 ]]; then bad=1; fi
    done
  done
  if [[ $bad -ne 0 && $n -gt 1 && ${CH[ACL]:-0} == 1 ]]; then
    printf '  %s提示：本链路开启了来源白名单，上一跳的出口 IP 不在名单内时也会显示不可达；可在该跳节点执行 nxr edit <端口> --allow - 取消%s\n' "$C_GRY" "$C_RST"
  fi
  [[ $bad -eq 0 ]]
}

chain_check_any() {
  local id rc=0
  if [[ $1 == all ]]; then
    for id in $(chain_ids); do chain_check "$id" || rc=1; done
    return "$rc"
  fi
  chain_check "$1"
}

chain_delete() {
  local cid=$1 n i k fails=0 out
  local -a tn tp
  chain_load "$cid" || { err "链路不存在: $cid"; return 1; }
  n=${CH[HOPS]}
  for (( i = 1; i <= n; i++ )); do
    tier_parse "${CH[HOP_$i]}"
    tn=("${M_NODE[@]}"); tp=("${M_PORT[@]}")
    for k in "${!tn[@]}"; do
      if out=$(node_nxr "${tn[k]}" del "${tp[k]}" --chain "$cid" --yes 2>&1); then
        ok "[${tn[k]}] 已删除第 $i 跳 :${tp[k]}"
      else
        fails=$((fails + 1))
        err "[${tn[k]}] 删除第 $i 跳失败: $(tail -n1 <<<"$out")"
      fi
    done
  done
  # -y 不能替用户放弃失联节点上的规则，只有 --force 或交互确认才删除记录
  if [[ $fails -gt 0 ]]; then
    if [[ $OPT_FORCE != 1 ]] && ! { [[ -t 0 && $ASSUME_YES != 1 ]] && confirm "有 $fails 个节点清理失败，仍删除链路记录?" N; }; then
      warn "链路 $cid 的记录已保留：节点恢复后重新执行删除；确认放弃这些节点上的规则可加 --force"
      return 1
    fi
  fi
  rm -f "$CHAIN_DIR/$cid.conf"
  ok "链路 $cid 已删除"
}

chain_show() {
  local cid=$1 n i k
  chain_load "$cid" || { err "链路不存在: $cid"; return 1; }
  n=${CH[HOPS]}
  printf '  链路 %s「%s」  协议 %s  跳间传输 %s  创建于 %s\n' "$cid" "${CH[NAME]}" "$(proto_label "${CH[PROTO]}")" \
    "$(transport_label "${CH[TRANSPORT]}")" "${CH[CREATED]:--}"
  printf '  客户端连接   %s\n' "$(chain_entry "$cid")"
  chain_load "$cid"
  for (( i = 1; i <= n; i++ )); do
    tier_parse "${CH[HOP_$i]}"
    for k in "${!M_NODE[@]}"; do
      if [[ $i -eq 1 ]]; then
        printf '  第1跳        [%s] 监听 :%s\n' "${M_NODE[k]}" "${M_PORT[k]}"
      else
        printf '  第%d跳        [%s] %s\n' "$i" "${M_NODE[k]}" "$(join_hostport "${M_ADDR[k]}" "${M_PORT[k]}")"
      fi
      if [[ -n ${M_IFACE[k]}${M_THROUGH[k]} ]]; then printf '               出站 %s %s\n' "${M_IFACE[k]}" "${M_THROUGH[k]}"; fi
      if [[ $i -eq $n ]]; then printf '               → 出口 %s\n' "$(targets_for "${M_NODE[k]}" "${CH[TARGET]}" | sed 's/,/ | /g')"; fi
    done
  done
  printf '  分流方式     多 IX：%s / 多出口：%s\n' "$(mode_label "${CH[MODE]}")" "$(mode_label "${CH[TARGET_MODE]}")"
  if [[ $n -gt 1 ]]; then
    if [[ ${CH[ACL]:-0} == 1 ]]; then
      echo "  来源白名单   已开启：第 2 跳起只接受上一跳节点的连接"
    else
      echo "  来源白名单   未开启"
    fi
  fi
}

chain_route() { # 当前 CH 的路线简写
  local i n=${CH[HOPS]} r=""
  for (( i = 1; i <= n; i++ )); do r+="$(tier_str "${CH[HOP_$i]}") → "; done
  echo "$r$(targets_str "${CH[TARGET]}")"
}

chain_table() {
  local id
  local -a ids
  mapfile -t ids < <(chain_ids)
  if [[ ${#ids[@]} -eq 0 ]]; then echo "  （暂无链路）"; return 1; fi
  for id in "${ids[@]}"; do
    chain_load "$id" || continue
    printf '  %s%-4s%s %-4s %s  「%s」%s\n' "$C_CYN" "$id" "$C_RST" "$(proto_short "${CH[PROTO]}")" "$(chain_route)" "${CH[NAME]}" "$(chain_state_note)"
  done
}

# 拓扑总览：按前置分组列出所有线路
chain_topo() {
  local id e k i port route branch host
  local -a ids order cl
  local -A grp=()
  mapfile -t ids < <(chain_ids)
  if [[ ${#ids[@]} -eq 0 ]]; then echo "  （暂无链路）"; return 1; fi
  for id in "${ids[@]}"; do
    chain_load "$id" || continue
    tier_parse "${CH[HOP_1]}"
    e=${M_NODE[0]}
    if [[ -z ${grp[$e]+x} ]]; then order+=("$e"); grp[$e]=""; fi
    grp[$e]+="$id "
  done
  for e in "${order[@]}"; do
    if [[ $e == local ]]; then host="本机"; else host=$(kv_get "$(node_path "$e")" HOST); fi
    printf '  %s前置 %s%s（%s）\n' "$C_BLD" "$e" "$C_RST" "$host"
    read -ra cl <<<"${grp[$e]}"
    for k in "${!cl[@]}"; do
      chain_load "${cl[k]}" || continue
      tier_parse "${CH[HOP_1]}"
      port=${M_PORT[0]}
      route=""
      for (( i = 2; i <= ${CH[HOPS]}; i++ )); do route+="$(tier_str "${CH[HOP_$i]}") → "; done
      route+=$(targets_str "${CH[TARGET]}")
      if (( k == ${#cl[@]} - 1 )); then branch="└─"; else branch="├─"; fi
      printf '  %s :%-6s %s%-4s%s → %s  「%s」%s%s\n' "$branch" "$port" "$C_CYN" "${cl[k]}" "$C_RST" "$route" "${CH[NAME]}" "$(chain_mode_desc)" "$(chain_state_note)"
    done
  done
}

# 一个前置 · 多个 IX · 多个出口，一次开出多条线路
chain_batch_wizard() {
  local front c i k x t name addr def per proto tmode="none" combo fp iq q clash need_mode=0 need_tmode=0 okall ok_lines=0 cid r a b d
  local -a IXN=() IXA=() EXN=() EXT=() LN=() LIX=() LEX=() LFP=() LIQ=() RES=() sel=() tl=() mem=() ixs=()
  local -A USED=()
  title "批量开线路（一个前置 · 多个 IX · 多个出口）"
  cat <<'EOF'
  在一台前置上一次开出多条线路，每条线路占用前置的一个入口端口（客户端连不同端口就走不同线路）。
  · 一条线路可以同时经过多台 IX：主备切换或负载均衡，某台 IX 故障时自动绕开
  · 一个出口可以是多台配置相同的落地：同样支持主备或负载均衡
  · 也可以让「每台 IX × 每个出口」各开一条独立线路，用端口区分
EOF
  hr
  ensure_ssh_client >/dev/null 2>&1 || true
  self_install || true

  printf '  %s1. 前置节点%s\n' "$C_BLD" "$C_RST"
  while :; do
    pick_node front "0" || return 1
    node_prepare "$front" && break
    confirm "节点准备失败，重新选择?" Y || return 1
  done

  echo
  printf '  %s2. IX 节点（可多选）%s\n' "$C_BLD" "$C_RST"
  while :; do
    pick_nodes "选择 IX 节点" 0 || return 1
    if [[ " ${PICKED[*]} " == *" $front "* ]]; then err "IX 不能选前置本身"; continue; fi
    okall=1
    for x in "${PICKED[@]}"; do node_prepare "$x" || okall=0; done
    [[ $okall == 1 ]] && break
    confirm "有节点准备失败，重新选择?" Y || return 1
  done
  for x in "${PICKED[@]}"; do
    node_load "$x"
    def=${N_ADDR:-$N_HOST}
    while :; do ask addr "前置连接 [$x] 使用的地址" "$def" || return 1; is_host "$addr" && break; err "地址无效"; done
    IXN+=("$x"); IXA+=("$addr")
  done

  echo
  printf '  %s3. 出口（落地）%s\n' "$C_BLD" "$C_RST"
  echo "  · 地址填 IX 访问落地用的 IP:端口；多台配置相同的落地用逗号分隔，合成一个出口做冗余"
  while :; do
    ask name "出口名称（如 hk1；直接回车结束添加）" "" || return 1
    if [[ -z $name ]]; then
      [[ ${#EXN[@]} -gt 0 ]] && break
      err "至少添加一个出口"; continue
    fi
    if ! is_name "$name"; then err "名称只能用字母、数字和 - _ ."; continue; fi
    if [[ " ${EXN[*]} " == *" $name "* ]]; then err "出口名称重复"; continue; fi
    while :; do
      ask addr "[$name] 地址:端口" "" || return 1
      addr=${addr// /}
      [[ -n $addr ]] && valid_hostport_list "$addr" && break
      err "格式无效"
    done
    t=$addr
    if [[ ${#IXN[@]} -gt 1 ]] && confirm "各台 IX 访问 [$name] 的地址不同?" N; then
      t=""
      for x in "${IXN[@]}"; do
        while :; do
          ask per "[$x] 访问 [$name] 的地址:端口" "$addr" || return 1
          per=${per// /}
          valid_hostport_list "$per" && break
          err "格式无效"
        done
        IFS=, read -ra tl <<<"$per"
        for k in "${tl[@]}"; do t+="${t:+,}$x=$k"; done
      done
    fi
    EXN+=("$name"); EXT+=("$t")
  done

  echo
  printf '  %s4. 线路组合%s\n' "$C_BLD" "$C_RST"
  echo "    1) 每个出口一条线路，同时经过全部所选 IX（多 IX 冗余）  → ${#EXN[@]} 条"
  echo "    2) 每台 IX × 每个出口各一条线路（用端口区分）         → $(( ${#IXN[@]} * ${#EXN[@]} )) 条"
  echo "    3) 逐个出口指定经过哪些 IX"
  ask combo "请选择" "1" || return 1
  case $combo in
    2)
      for i in "${!IXN[@]}"; do
        for k in "${!EXN[@]}"; do LN+=("${IXN[i]}-${EXN[k]}"); LIX+=("$i"); LEX+=("$k"); done
      done ;;
    3)
      for k in "${!EXN[@]}"; do
        printf '    IX：'
        for i in "${!IXN[@]}"; do printf '%d) %s  ' $((i + 1)) "${IXN[i]}"; done
        echo
        while :; do
          ask x "[${EXN[k]}] 经过哪些 IX（序号空格分隔）" "$(seq -s ' ' 1 ${#IXN[@]})" || return 1
          sel=()
          for i in $x; do
            if [[ $i =~ ^[0-9]+$ ]] && (( i >= 1 && i <= ${#IXN[@]} )) && [[ " ${sel[*]} " != *" $((i - 1)) "* ]]; then sel+=($((i - 1))); fi
          done
          [[ ${#sel[@]} -gt 0 ]] && break
          err "至少选一台 IX"
        done
        LN+=("${EXN[k]}"); LIX+=("${sel[*]}"); LEX+=("$k")
      done ;;
    *)
      for k in "${!EXN[@]}"; do LN+=("${EXN[k]}"); LIX+=("$(seq -s ' ' 0 $(( ${#IXN[@]} - 1 )))"); LEX+=("$k"); done ;;
  esac

  C_MODE=failover; C_TMODE=failover
  for i in "${!LN[@]}"; do
    if [[ ${LIX[i]} == *' '* ]]; then need_mode=1; fi
  done
  for k in "${!EXN[@]}"; do
    for x in "${IXN[@]}"; do
      if [[ $(targets_for "$x" "${EXT[k]}") == *,* ]]; then need_tmode=1; fi
    done
  done
  if [[ $need_mode == 1 ]]; then echo; pick_mode C_MODE "一条线路经过多台 IX 时，前置如何分配流量" || return 1; fi
  if [[ $need_tmode == 1 ]]; then echo; pick_mode C_TMODE "一个出口有多台落地时，IX 如何分配流量" || return 1; fi

  echo
  printf '  %s5. 端口与协议%s\n' "$C_BLD" "$C_RST"
  ask fp "前置入口端口起始值（自动跳过已占用）" "10001" || return 1
  ask iq "IX 端口起始值" "20001" || return 1
  if ! is_port "$fp" || ! is_port "$iq"; then err "端口无效"; return 1; fi
  echo "  转发协议：1) TCP+UDP（默认）  2) 仅 TCP  3) 仅 UDP"
  ask c "请选择" "1" || return 1
  case $c in 2) proto=tcp ;; 3) proto=udp ;; *) proto=both ;; esac
  TL_LISTEN=""; TL_REMOTE=""
  if [[ $proto != udp ]]; then ask_transport tmode || return 1; fi
  C_ACL=0
  if confirm "IX 端口只接受前置的连接（来源 IP 白名单，防止端口被扫描盗用）?" Y; then C_ACL=1; fi

  info "读取各节点已占用端口..."
  USED[$front]=" $(node_nxr "$front" used-ports 2>/dev/null | tr '\n' ' ') "
  for x in "${IXN[@]}"; do USED[$x]=" $(node_nxr "$x" used-ports 2>/dev/null | tr '\n' ' ') "; done
  for i in "${!LN[@]}"; do
    while [[ ${USED[$front]} == *" $fp "* ]]; do fp=$((fp + 1)); done
    LFP+=("$fp"); USED[$front]+="$fp "; fp=$((fp + 1))
    q=$iq
    while :; do
      clash=0
      for k in ${LIX[i]}; do
        if [[ ${USED[${IXN[k]}]} == *" $q "* ]]; then clash=1; fi
      done
      [[ $clash == 0 ]] && break
      q=$((q + 1))
    done
    LIQ+=("$q")
    for k in ${LIX[i]}; do USED[${IXN[k]}]+="$q "; done
    iq=$((q + 1))
  done
  if (( fp > 65535 || iq > 65535 )); then err "端口超出范围"; return 1; fi

  echo
  hr
  printf '  共 %d 条线路 · 前置 %s · 协议 %s · 跳间 %s\n' "${#LN[@]}" "$front" "$(proto_label "$proto")" "$(transport_label "$tmode")"
  if [[ $need_mode == 1 ]]; then printf '  多 IX 分流：%s\n' "$(mode_label "$C_MODE")"; fi
  if [[ $need_tmode == 1 ]]; then printf '  多出口分流：%s\n' "$(mode_label "$C_TMODE")"; fi
  for i in "${!LN[@]}"; do
    ixs=()
    for k in ${LIX[i]}; do ixs+=("${IXN[k]}:${LIQ[i]}"); done
    t=$(IFS='|'; echo "${ixs[*]}")
    printf '  %-20s 入口 :%-6s → %s → %s %s\n' "${LN[i]}" "${LFP[i]}" "${t//|/ | }" "${EXN[${LEX[i]}]}" \
      "$(targets_str "$(targets_keep "${EXT[${LEX[i]}]}" "${ixs[@]%%:*}")")"
  done
  hr
  confirm "确认部署这 ${#LN[@]} 条线路?" Y || return 1

  for i in "${!LN[@]}"; do
    cid=$(chain_next_id)
    local -a H_SPEC=()
    H_SPEC[1]="$front|${LFP[i]}|||"
    mem=(); ixs=()
    for k in ${LIX[i]}; do mem+=("${IXN[k]}|${LIQ[i]}|${IXA[k]}||"); ixs+=("${IXN[k]}"); done
    H_SPEC[2]=$(IFS=';'; echo "${mem[*]}")
    C_TARGETS=$(targets_keep "${EXT[${LEX[i]}]}" "${ixs[@]}")
    CHAIN_USED=" "
    printf '\n  %s[%d/%d] 线路 %s%s\n' "$C_BLD" $((i + 1)) "${#LN[@]}" "${LN[i]}" "$C_RST"
    if chain_deploy "$cid" "${LN[i]}" "$proto" "$tmode" 2 1; then
      RES+=("${LN[i]}|$cid|$CHAIN_ENTRY|ok"); ok_lines=$((ok_lines + 1))
    else
      RES+=("${LN[i]}|-|-|fail")
    fi
  done

  echo
  hr
  printf '  %s批量结果：成功 %d / %d%s\n' "$C_BLD" "$ok_lines" "${#LN[@]}" "$C_RST"
  for r in "${RES[@]}"; do
    IFS='|' read -r a b c d <<<"$r"
    if [[ $d == ok ]]; then
      printf '  %s✓%s %-20s %-4s 客户端连接 %s\n' "$C_GRN" "$C_RST" "$a" "$b" "$c"
    else
      printf '  %s✗%s %-20s 部署失败\n' "$C_RED" "$C_RST" "$a"
    fi
  done
  echo "  （客户端使用对应出口落地服务的协议参数，服务器地址/端口改成上面的入口）"
  [[ $ok_lines -eq ${#LN[@]} ]]
}

# ================================================================== 展示
states_load() {
  declare -gA ST=()
  local -a ids units out
  local id i
  mapfile -t ids < <(rule_ids)
  [[ ${#ids[@]} -eq 0 ]] && return 0
  if [[ $INIT == systemd ]]; then
    for id in "${ids[@]}"; do units+=("nxr@$id.service"); done
    mapfile -t out < <(systemctl is-active "${units[@]}" 2>/dev/null)
    for i in "${!ids[@]}"; do ST[${ids[i]}]=${out[i]:-inactive}; done
  else
    for id in "${ids[@]}"; do ST[$id]=$(svc_state "$id"); done
  fi
}

state_label() { # state_label 启用 状态 → 彩色两字状态
  if [[ $1 != 1 ]]; then printf '%s停用%s' "$C_GRY" "$C_RST"; return; fi
  case $2 in
    active) printf '%s运行%s' "$C_GRN" "$C_RST" ;;
    activating) printf '%s重启%s' "$C_YLW" "$C_RST" ;;
    failed) printf '%s失败%s' "$C_RED" "$C_RST" ;;
    *) printf '%s停止%s' "$C_RED" "$C_RST" ;;
  esac
}

rule_display_name() {
  if [[ -n $R_CHAIN ]]; then printf '[%s] %s' "$R_CHAIN" "$R_NAME"; else printf '%s' "$R_NAME"; fi
}

rules_table() {
  local id t sfx rx tx acct
  local -a ids
  mapfile -t ids < <(rule_ids)
  if [[ ${#ids[@]} -eq 0 ]]; then echo "  （暂无规则）"; return 1; fi
  states_load
  printf '  %s端口   状态 监听                   目标                         协议  连接       入站       出站  名称%s\n' "$C_BLD" "$C_RST"
  for id in "${ids[@]}"; do
    rule_load "$id" || continue
    t=$(rule_target)
    sfx=""
    if [[ -n $R_EXTRA_REMOTES ]]; then sfx=" +$(( $(tr -cd ',' <<<"$R_EXTRA_REMOTES" | wc -c) + 1 ))"; fi
    if [[ -n $R_BACKUPS ]]; then sfx=" ~$(( $(tr -cd ',' <<<"$R_BACKUPS" | wc -c) + 1 ))"; fi
    if [[ -n $R_ACTIVE_REMOTE ]]; then sfx+="*"; fi
    if (( ${#t} + ${#sfx} > 28 )); then t="${t:0:$(( 27 - ${#sfx} ))}~"; fi
    t+=$sfx
    read -r rx tx <<<"$(acct_get "$id")"
    printf '  %-6s %s %-22s %-28s %-4s %5s %10s %10s  %s\n' "$id" "$(state_label "$R_ENABLED" "${ST[$id]}")" \
      "$(join_hostport "$R_LISTEN_ADDR" "$R_LISTEN_PORT")" "$t" "$(proto_short "$R_PROTO")" \
      "$(conn_count "$id")" "$(fmt_bytes "$rx")" "$(fmt_bytes "$tx")" "$(rule_display_name)"
  done
  acct=$(acct_backend)
  printf '  %s入站=客户端→本机  出站=本机→客户端  统计: %s   +N 负载均衡附加目标  ~N 备用目标  * 已切到备用%s\n' "$C_GRY" "$acct" "$C_RST"
}

rules_brief() {
  local id
  local -a ids
  mapfile -t ids < <(rule_ids)
  if [[ ${#ids[@]} -eq 0 ]]; then echo "  （暂无规则）"; return 1; fi
  states_load
  for id in "${ids[@]}"; do
    rule_load "$id" || continue
    printf '  %-6s %s  %s → %s  %s\n' "$id" "$(state_label "$R_ENABLED" "${ST[$id]}")" \
      "$(join_hostport "$R_LISTEN_ADDR" "$R_LISTEN_PORT")" "$(rule_target)" "$(rule_display_name)"
  done
}

pick_rule() {
  local __v=$1 id
  ask id "${2:-输入规则端口}" "" || return 1
  [[ -z $id ]] && return 1
  rule_exists "$id" || { err "规则不存在: $id"; return 1; }
  printf -v "$__v" '%s' "$id"
}

rule_detail() {
  local id=$1 rx tx
  rule_load "$id" || { err "规则不存在: $id"; return 1; }
  read -r rx tx <<<"$(acct_get "$id")"
  printf '  规则端口     %s\n' "$R_ID"
  printf '  名称         %s\n' "${R_NAME:--}"
  printf '  状态         %s（%s）\n' "$(state_label "$R_ENABLED" "$(svc_state "$id")")" "$(svc_state "$id")"
  printf '  监听         %s  [%s]\n' "$(join_hostport "$R_LISTEN_ADDR" "$R_LISTEN_PORT")" "$(proto_label "$R_PROTO")"
  printf '  目标         %s\n' "$R_REMOTE"
  if [[ -n $R_BACKUPS ]]; then
    printf '  备用目标     %s（当前使用: %s，自动切回: %s）\n' "$R_BACKUPS" "$(rule_target)" "$([[ $R_SWITCHBACK == 1 ]] && echo 是 || echo 否)"
  fi
  if [[ -n $R_EXTRA_REMOTES ]]; then
    printf '  负载均衡     %s  附加目标 %s\n' "$R_BALANCE" "$R_EXTRA_REMOTES"
    printf '  健康检查     %s\n' "$([[ $R_HEALTH == 1 ]] && echo "开（当前不可用: ${R_DOWN:-无}）" || echo 关)"
  fi
  if [[ -n $R_IFACE$R_THROUGH ]]; then printf '  出站         网卡 %s  源 IP %s\n' "${R_IFACE:-自动}" "${R_THROUGH:-自动}"; fi
  if [[ -n $R_LISTEN_TRANSPORT$R_REMOTE_TRANSPORT ]]; then
    printf '  加密传输     监听 %s / 出站 %s\n' "${R_LISTEN_TRANSPORT:-无}" "${R_REMOTE_TRANSPORT:-无}"
  fi
  if [[ $R_SEND_PROXY == 1 || $R_ACCEPT_PROXY == 1 ]]; then
    printf '  PROXY 协议   发送 %s / 接收 %s\n' "$R_SEND_PROXY" "$R_ACCEPT_PROXY"
  fi
  if [[ -n $R_ALLOW ]]; then printf '  来源白名单   %s（其余来源一律丢弃）\n' "$R_ALLOW"; fi
  if [[ -n $R_CHAIN ]]; then printf '  所属链路     %s（%s）\n' "$R_CHAIN" "${R_ROLE:--}"; fi
  printf '  连接数       %s\n' "$(conn_count "$id")"
  printf '  流量         入站 %s / 出站 %s\n' "$(fmt_bytes "$rx")" "$(fmt_bytes "$tx")"
  printf '  创建时间     %s\n' "${R_CREATED:--}"
  printf '  realm 配置   %s\n' "$REALM_CONF_DIR/$id.toml"
}

# ================================================================== 规则编辑
pick_transport() { # pick_transport listen|remote 当前值 → PT_RESULT
  local side=$1 cur=$2 c sni="www.bing.com" host="www.bing.com" path="/nxr"
  echo "    0) 保持当前（${cur:-不加密}）  1) 不加密  2) TLS  3) WebSocket  4) WebSocket+TLS  5) 自定义参数"
  echo "    （两端必须对应：上一跳的「出站」与下一跳的「监听」选择相同方式和参数）"
  ask c "请选择" "0" || return 1
  case $c in
    0) PT_RESULT=$cur; return 0 ;;
    1) PT_RESULT=""; return 0 ;;
    2) ask sni "TLS SNI/证书域名" "$sni" || return 1; transport_build tls "$sni" ;;
    3) ask host "WebSocket Host" "$host" || return 1; ask path "WebSocket 路径" "$path" || return 1; transport_build ws "" "$host" "$path" ;;
    4)
      ask sni "TLS SNI/证书域名" "$sni" || return 1
      ask host "WebSocket Host" "$host" || return 1
      ask path "WebSocket 路径" "$path" || return 1
      transport_build wss "$sni" "$host" "$path" ;;
    5)
      ask PT_RESULT "kaminari 参数（例如 tls;sni=a.com;insecure）" "$cur" || return 1
      return 0 ;;
    *) PT_RESULT=$cur; return 0 ;;
  esac
  if [[ $side == listen ]]; then PT_RESULT=$TL_LISTEN; else PT_RESULT=$TL_REMOTE; fi
}

edit_hostport_list() { # edit_hostport_list 变量名 提示
  local __v=$1 cur=${!1} val
  echo "  当前: ${cur:-无}   格式: host:port,host:port   输入 - 清空"
  ask val "$2" "$cur" || return 1
  [[ $val == - ]] && val=""
  val=${val// /}
  if [[ -n $val ]] && ! valid_hostport_list "$val"; then err "格式无效"; return 1; fi
  printf -v "$__v" '%s' "$val"
}

rule_editor() {
  local c v h p sb
  [[ -z $R_LISTEN_ADDR ]] && R_LISTEN_ADDR=$(default_listen_addr)
  while :; do
    title "规则设置 · 端口 $R_LISTEN_PORT"
    sb="关闭"
    [[ -n $R_BACKUPS ]] && sb="备用 $R_BACKUPS（自动切回: $([[ $R_SWITCHBACK == 1 ]] && echo 是 || echo 否)）"
    printf '   1. 监听地址/端口   %s\n' "$(join_hostport "$R_LISTEN_ADDR" "$R_LISTEN_PORT")"
    printf '   2. 目标地址        %s\n' "$R_REMOTE"
    printf '   3. 协议            %s\n' "$(proto_label "$R_PROTO")"
    printf '   4. 备注名称        %s\n' "${R_NAME:--}"
    printf '   5. 出站网卡        %s\n' "${R_IFACE:-自动}"
    printf '   6. 出站源 IP       %s\n' "${R_THROUGH:-自动}"
    printf '   7. 负载均衡        %s\n' "$([[ -n $R_EXTRA_REMOTES ]] && echo "$R_BALANCE，附加 $R_EXTRA_REMOTES" || echo 关闭)"
    printf '   8. 主备切换        %s\n' "$sb"
    printf '   9. 加密传输        监听 %s / 出站 %s\n' "${R_LISTEN_TRANSPORT:-无}" "${R_REMOTE_TRANSPORT:-无}"
    printf '  10. PROXY 协议      发送 %s / 接收 %s\n' "$([[ $R_SEND_PROXY == 1 ]] && echo 开 || echo 关)" "$([[ $R_ACCEPT_PROXY == 1 ]] && echo 开 || echo 关)"
    printf '  11. DNS 解析策略    %s\n' "${R_DNS_MODE:-默认 ipv4_and_ipv6}"
    printf '  12. 入站网卡绑定    %s\n' "${R_LISTEN_IFACE:-不绑定}"
    printf '  13. 来源 IP 白名单  %s\n' "${R_ALLOW:-不限制}"
    hr
    echo "   s. 保存并应用        0. 放弃修改"
    read_choice c
    case $c in
      1)
        ask v "监听地址（:: 双栈 / 0.0.0.0 仅 IPv4 / 指定本机 IP）" "$R_LISTEN_ADDR" || continue
        v=${v#[}; v=${v%]}
        if is_ip "$v"; then R_LISTEN_ADDR=$v; else err "地址无效"; pause; continue; fi
        ask v "监听端口" "$R_LISTEN_PORT" || continue
        if is_port "$v"; then R_LISTEN_PORT=$v; else err "端口无效"; pause; fi ;;
      2)
        split_hostport "$R_REMOTE"
        ask h "目标地址（IP/域名）" "$HP_HOST" || continue
        h=${h#[}; h=${h%]}
        ask p "目标端口" "$HP_PORT" || continue
        if is_host "$h" && is_port "$p"; then R_REMOTE=$(join_hostport "$h" "$p"); else err "目标无效"; pause; fi ;;
      3)
        echo "    1) TCP+UDP  2) 仅 TCP  3) 仅 UDP"
        ask v "请选择" "1" || continue
        case $v in 2) R_PROTO=tcp ;; 3) R_PROTO=udp ;; *) R_PROTO=both ;; esac ;;
      4) ask v "备注名称（- 清空）" "$R_NAME" || continue; [[ $v == - ]] && v=""; if is_text "$v"; then R_NAME=$v; else err "名称无效"; pause; fi ;;
      5)
        local_ifaces | awk '{printf "      %-10s %s\n", $1, $2}'
        ask v "出站网卡（- 清空为自动）" "$R_IFACE" || continue
        [[ $v == - ]] && v=""
        if [[ -z $v ]] || is_iface "$v"; then R_IFACE=$v; else err "网卡名无效"; pause; fi ;;
      6)
        local_ifaces | awk '{printf "      %-10s %s\n", $1, $2}'
        ask v "出站源 IP（- 清空为自动）" "$R_THROUGH" || continue
        [[ $v == - ]] && v=""
        if [[ -z $v ]] || is_ip "$v"; then R_THROUGH=$v; else err "IP 无效"; pause; fi ;;
      7)
        echo "  负载均衡：主目标 + 附加目标按策略分配连接；开启健康检查后不可达的目标自动摘除（与主备切换二选一）"
        edit_hostport_list R_EXTRA_REMOTES "附加目标" || { pause; continue; }
        if [[ -n $R_EXTRA_REMOTES ]]; then
          R_BACKUPS=""; R_ACTIVE_REMOTE=""
          echo "    1) roundrobin 轮询   2) iphash 同一来源 IP 固定目标"
          ask v "策略" "1" || continue
          if [[ $v == 2 ]]; then v=iphash; else v=roundrobin; fi
          ask h "权重（逗号分隔，个数=1+附加目标数，回车均分）" "" || continue
          if [[ -n $h ]]; then R_BALANCE="$v: $h"; else R_BALANCE=$v; fi
          if confirm "开启健康检查（每 30 秒探测，不可达的目标自动摘除，恢复后加回）?" Y; then R_HEALTH=1; else R_HEALTH=0; fi
        else
          R_BALANCE=""; R_HEALTH=0; R_DOWN=""
        fi ;;
      8)
        echo "  主备切换：nxr 每 30 秒探测当前目标，连续失败自动切到可用的备用目标（仅 TCP 探测，与负载均衡二选一）"
        edit_hostport_list R_BACKUPS "备用目标（按优先级）" || { pause; continue; }
        if [[ -n $R_BACKUPS ]]; then R_EXTRA_REMOTES=""; R_BALANCE=""; R_HEALTH=0; R_DOWN=""; fi
        if [[ -n $R_BACKUPS ]]; then
          if confirm "主目标恢复后自动切回?" Y; then R_SWITCHBACK=1; else R_SWITCHBACK=0; fi
        else
          R_ACTIVE_REMOTE=""
        fi ;;
      9)
        echo "  监听端（接收上一跳的加密流量）："
        pick_transport listen "$R_LISTEN_TRANSPORT" && R_LISTEN_TRANSPORT=$PT_RESULT
        echo "  出站端（加密发往下一跳）："
        pick_transport remote "$R_REMOTE_TRANSPORT" && R_REMOTE_TRANSPORT=$PT_RESULT ;;
      10)
        if confirm "向目标发送 PROXY 协议头（落地服务需支持，用于传递真实客户端 IP）?" N; then R_SEND_PROXY=1; else R_SEND_PROXY=0; fi
        if confirm "要求入站连接携带 PROXY 协议头（上一跳开启发送时才启用）?" N; then R_ACCEPT_PROXY=1; else R_ACCEPT_PROXY=0; fi ;;
      11)
        echo "    1) 默认 ipv4_and_ipv6  2) ipv4_only  3) ipv6_only  4) ipv4_then_ipv6  5) ipv6_then_ipv4"
        ask v "请选择" "1" || continue
        case $v in 2) R_DNS_MODE=ipv4_only ;; 3) R_DNS_MODE=ipv6_only ;; 4) R_DNS_MODE=ipv4_then_ipv6 ;; 5) R_DNS_MODE=ipv6_then_ipv4 ;; *) R_DNS_MODE="" ;; esac ;;
      12)
        local_ifaces | awk '{printf "      %-10s %s\n", $1, $2}'
        ask v "只在指定网卡上接收连接（- 清空）" "$R_LISTEN_IFACE" || continue
        [[ $v == - ]] && v=""
        if [[ -z $v ]] || is_iface "$v"; then R_LISTEN_IFACE=$v; else err "网卡名无效"; pause; fi ;;
      13)
        echo "  只允许这些来源 IP 连接本端口，其余一律丢弃（IX/中转机填上一跳的地址，防止端口被扫描盗用）"
        echo "  格式: IP 或 IP/前缀，逗号分隔，例如 203.0.113.5,10.1.0.0/24   输入 - 清空（不限制）"
        ask v "来源白名单" "$R_ALLOW" || continue
        [[ $v == - ]] && v=""
        R_ALLOW=${v// /} ;;
      s|S) return 0 ;;
      0) return 1 ;;
    esac
  done
}

# ================================================================== 菜单
menu_realm() {
  local c v latest
  while :; do
    title "安装 / 更新 realm"
    printf '  当前版本   %s\n' "$(realm_version || echo 未安装)"
    printf '  程序路径   %s\n' "$REALM_BIN"
    printf '  构建类型   %s（musl 为静态编译，兼容性最好）\n' "$REALM_LIBC"
    hr
    echo "  1. 在线安装 / 更新到最新版"
    echo "  2. 安装指定版本"
    echo "  3. 离线安装（上传 realm 压缩包或二进制到本机）"
    echo "  4. 切换构建类型 musl / gnu"
    echo "  0. 返回"
    read_choice c
    case $c in
      1) latest=$(realm_latest_tag); info "最新版本: $latest"; realm_install --version "$latest"; pause ;;
      2) ask v "版本号（如 v2.9.6）" "$REALM_FALLBACK_VERSION" && realm_install --version "$v" --force; pause ;;
      3)
        echo "  说明：在能访问 GitHub 的电脑下载 realm-<架构>-unknown-linux-musl.tar.gz，上传到本机后填写路径"
        printf '  本机架构 %s，应下载: realm-%s.tar.gz\n' "$(uname -m)" "$(realm_triple "$(uname -m)" "$REALM_LIBC")"
        ask v "文件路径" "/root/realm-$(realm_triple "$(uname -m)" "$REALM_LIBC").tar.gz" && realm_install --file "$v"
        pause ;;
      4)
        if [[ $REALM_LIBC == musl ]]; then REALM_LIBC=gnu; else REALM_LIBC=musl; fi
        save_global; ok "已切换为 $REALM_LIBC，重新安装后生效"; pause ;;
      0|"") return ;;
    esac
  done
}

menu_add() {
  local port host rport c ms
  title "添加转发规则"
  echo "  单机规则：本机端口 → 目标地址。多跳 IX 链路请用主菜单「8. 创建转发链路」。"
  echo
  rule_reset
  while :; do
    ask port "本机监听端口（回车随机）" "" || return
    [[ -z $port ]] && port=$(random_free_port)
    if ! is_port "$port"; then err "端口无效"; continue; fi
    if rule_exists "$port"; then err "端口 $port 已有规则"; continue; fi
    if port_in_use "$port"; then err "端口 $port 已被占用: $(port_owner "$port")"; continue; fi
    break
  done
  while :; do
    ask host "目标地址（下一跳或落地的 IP/域名）" "" || return
    host=${host#[}; host=${host%]}
    is_host "$host" && break
    err "地址无效"
  done
  while :; do ask rport "目标端口" "$port" || return; is_port "$rport" && break; err "端口无效"; done
  R_LISTEN_PORT=$port
  R_REMOTE=$(join_hostport "$host" "$rport")
  echo "  协议：1) TCP+UDP  2) 仅 TCP  3) 仅 UDP"
  ask c "请选择" "1" || return
  case $c in 2) R_PROTO=tcp ;; 3) R_PROTO=udp ;; *) R_PROTO=both ;; esac
  ask R_NAME "备注名称（可选）" "" || return
  is_text "$R_NAME" || R_NAME=""
  info "探测目标 $R_REMOTE"
  if ms=$(tcp_probe "$host" "$rport" 3); then ok "目标可达，延迟 ${ms}ms"; else warn "目标暂时不可达（服务未启动或仅 UDP 时可忽略）"; fi
  if confirm "进入高级设置?（出站网卡/源IP、负载均衡、主备切换、加密传输、PROXY 协议、DNS）" N; then
    rule_editor || return
  fi
  while :; do
    rule_commit
    [[ $? -eq 2 ]] || break
    warn "设置有误，请修改后重新保存（0 放弃）"
    rule_editor || return
  done
  pause
}

menu_list() {
  local c id
  while :; do
    title "规则列表"
    rules_table
    hr
    echo "  d. 规则详情   t. 清零某条规则的流量统计   回车 刷新   0. 返回"
    read_choice c
    case $c in
      d|D) pick_rule id && { echo; rule_detail "$id"; }; pause ;;
      t|T) pick_rule id && { with_lock acct_reset "$id"; ok "已清零"; }; pause ;;
      0) return ;;
    esac
  done
}

menu_edit() {
  local id
  title "修改规则"
  rules_brief || { pause; return; }
  echo
  pick_rule id || { pause; return; }
  rule_load "$id"
  if [[ -n $R_CHAIN ]]; then warn "该规则属于链路 $R_CHAIN（$R_ROLE），单独修改可能导致链路其他跳不一致"; pause; fi
  rule_editor || return
  while :; do
    rule_commit "$id"
    [[ $? -eq 2 ]] || break
    warn "设置有误，请修改后重新保存（0 放弃）"
    rule_editor || return
  done
  pause
}

menu_delete() {
  local ids id cs
  title "删除规则"
  rules_brief || { pause; return; }
  echo
  ask ids "输入要删除的规则端口（多个用空格分隔，all 表示全部）" "" || return
  [[ -z $ids ]] && return
  [[ $ids == all ]] && ids=$(rule_ids | tr '\n' ' ')
  for id in $ids; do
    if ! rule_exists "$id"; then warn "规则 $id 不存在"; continue; fi
    cs=$(kv_get "$(rule_path "$id")" CHAIN)
    if [[ -n $cs ]]; then warn "规则 $id 属于链路 $cs，建议在「链路管理」中整体删除"; fi
  done
  confirm "确认删除: $ids ?" N || return
  for id in $ids; do
    rule_exists "$id" || continue
    rule_purge "$id" && ok "已删除规则 $id"
  done
  watch_setup
  pause
}

menu_toggle() {
  local id
  title "启用 / 停用规则"
  rules_brief || { pause; return; }
  echo
  pick_rule id || { pause; return; }
  rule_load "$id"
  if [[ $R_ENABLED == 1 ]]; then
    confirm "停用规则 $id?" Y && rule_set_enabled "$id" 0
  else
    confirm "启用规则 $id?" Y && rule_set_enabled "$id" 1
  fi
  pause
}

menu_restart() {
  local id
  title "重启规则"
  rules_brief || { pause; return; }
  echo
  ask id "输入规则端口（all 重启全部）" "" || return
  [[ -z $id ]] && return
  if [[ $id == all ]]; then
    apply_all && ok "全部规则已重启"
  elif rule_exists "$id"; then
    rule_load "$id"
    if [[ $R_ENABLED != 1 ]]; then warn "规则已停用"; elif rule_start_verify "$id"; then ok "规则 $id 已重启"; fi
  else
    err "规则不存在"
  fi
  pause
}

menu_chains() {
  local c cid
  while :; do
    title "链路管理 · 拓扑总览"
    chain_topo
    hr
    echo "  1. 批量开线路（一个前置 · 多个 IX · 多个出口）"
    echo "  2. 新建单条链路（支持多 IX / 多出口）"
    echo "  3. 检测链路（逐跳服务状态与到下一跳的延迟，all 为全部）"
    echo "  4. 链路详情"
    echo "  5. 删除链路（清理所有节点上的对应规则）"
    echo "  0. 返回"
    read_choice c
    case $c in
      1) chain_batch_wizard; pause ;;
      2) chain_wizard; pause ;;
      3) ask cid "链路 ID" "all" && chain_check_any "$cid"; pause ;;
      4) ask cid "链路 ID" "$(chain_ids | head -n1)" && { echo; chain_show "$cid"; }; pause ;;
      5) ask cid "链路 ID" "" && [[ -n $cid ]] && confirm "确认删除链路 $cid 并清理各节点规则?" N && chain_delete "$cid"; pause ;;
      0|"") return ;;
    esac
  done
}

menu_nodes() {
  local c name n cmd
  while :; do
    title "节点管理（SSH）"
    if [[ $(node_count) -eq 0 ]]; then
      echo "  （暂无节点）"
    else
      for n in $(node_names); do
        node_load "$n"
        printf '  %s%-14s%s %s\n' "$C_CYN" "$n" "$C_RST" "$(node_label)"
      done
    fi
    hr
    echo "  1. 新增节点                 2. 测试全部节点"
    echo "  3. 安装公钥（免密登录）     4. 同步 nxr / realm 到节点"
    echo "  5. 打开节点上的 nxr 面板    6. 在节点上执行命令"
    echo "  7. 修改节点                 8. 删除节点"
    echo "  9. 查看本机 nxr 公钥（可手动添加到节点 authorized_keys）"
    echo "  0. 返回"
    read_choice c
    case $c in
      1) node_add_wizard; pause ;;
      2) for n in $(node_names); do node_test "$n"; done; pause ;;
      3) ask name "节点名称" "" && node_copy_key "$name"; pause ;;
      4) ask name "节点名称" "" && node_prepare "$name"; pause ;;
      5) ask name "节点名称" "" && node_exists "$name" && node_tty "$name" "$REMOTE_NXR" ;;
      6)
        ask name "节点名称" "" || continue
        node_exists "$name" || { err "节点不存在"; pause; continue; }
        ask cmd "要执行的命令" "uptime" || continue
        node_exec "$name" bash "$cmd"
        pause ;;
      7)
        ask name "节点名称" "" || continue
        node_load "$name" && [[ $name != local ]] || { err "节点不存在"; pause; continue; }
        ask N_HOST "SSH 地址" "$N_HOST"; ask N_PORT "SSH 端口" "$N_PORT"; ask N_USER "SSH 用户" "$N_USER"
        ask N_KEY "私钥路径（- 使用系统默认）" "${N_KEY:--}"; [[ $N_KEY == - ]] && N_KEY=""
        ask N_JUMP "跳板节点（- 不使用）" "${N_JUMP:--}"; [[ $N_JUMP == - ]] && N_JUMP=""
        ask N_ADDR "上一跳连接该节点使用的地址" "${N_ADDR:-$N_HOST}"; ask N_NOTE "备注" "$N_NOTE"
        if is_host "$N_HOST" && is_port "$N_PORT" && is_host "$N_ADDR" && is_text "$N_NOTE"; then node_save; ok "已保存"; node_test "$name"; else err "输入无效，未保存"; fi
        pause ;;
      8)
        ask name "节点名称" "" || continue
        if [[ -f $(node_path "$name") ]] && node_unused "$name" && confirm "删除节点 $name?（不会清理节点上的规则）" N; then
          rm -f "$(node_path "$name")"; ok "已删除"
        fi
        pause ;;
      9) ensure_nxr_key && { echo; cat "$NXR_KEY.pub"; echo; }; pause ;;
      0|"") return ;;
    esac
  done
}

tcping() {
  local h=$1 p=$2 n=${3:-4} i ms vals=""
  printf '  TCP 探测 %s 端口 %s\n' "$h" "$p"
  for (( i = 1; i <= n; i++ )); do
    if ms=$(tcp_probe "$h" "$p" 3); then
      printf '    #%d  %s ms\n' "$i" "$ms"
      vals+="$ms "
    else
      printf '    #%d  %s超时/拒绝%s\n' "$i" "$C_RED" "$C_RST"
    fi
    sleep 0.3
  done
  if [[ -n $vals ]]; then
    awk -v n="$n" -v v="$vals" 'BEGIN { c = split(v, a, " "); min = a[1]; max = a[1]; s = 0
      for (i = 1; i <= c; i++) { s += a[i]; if (a[i] < min) min = a[i]; if (a[i] > max) max = a[i] }
      printf "  成功 %d/%d  最小 %.1f  平均 %.1f  最大 %.1f ms\n", c, n, min, s / c, max }'
    return 0
  fi
  echo "  全部失败"
  return 1
}

menu_probe() {
  local c h p name id
  while :; do
    title "连通性 / 延迟测试"
    echo "  1. 本机 → 任意 主机:端口"
    echo "  2. 本机 → 全部规则的目标"
    echo "  3. 指定节点 → 主机:端口（SSH 远程测试，验证 IX/内网连通）"
    echo "  0. 返回"
    read_choice c
    case $c in
      1)
        ask h "主机" "" || continue; ask p "端口" "" || continue
        if is_host "$h" && is_port "$p"; then tcping "$h" "$p" 5; else err "输入无效"; fi
        pause ;;
      2)
        for id in $(rule_ids); do
          rule_load "$id"
          split_hostport "$(rule_target)"
          if ms=$(tcp_probe "$HP_HOST" "$HP_PORT" 3); then
            printf '  %-6s → %-30s %s%s ms%s\n' "$id" "$(rule_target)" "$C_GRN" "$ms" "$C_RST"
          else
            printf '  %-6s → %-30s %s不可达%s\n' "$id" "$(rule_target)" "$C_RED" "$C_RST"
          fi
        done
        pause ;;
      3)
        ask name "节点名称（local 为本机）" "" || continue
        node_exists "$name" || { err "节点不存在"; pause; continue; }
        ask h "主机" "" || continue; ask p "端口" "" || continue
        if is_host "$h" && is_port "$p"; then node_nxr "$name" probe "$h" "$p" 4; else err "输入无效"; fi
        pause ;;
      0|"") return ;;
    esac
  done
}

rule_diag() {
  local id=$1 st t x ms
  rule_load "$id" || { err "规则不存在"; return 1; }
  title "规则诊断 · $id"
  rule_detail "$id"
  hr
  st=$(svc_state "$id")
  if [[ $R_ENABLED != 1 ]]; then warn "规则已停用"; fi
  if [[ $st == active ]]; then ok "服务运行中"; else err "服务状态: $st"; fi
  if [[ $R_PROTO != udp ]]; then
    if rule_listening "$id" tcp; then ok "TCP 端口 $id 正在监听"; else err "TCP 端口 $id 未监听"; fi
  fi
  if [[ $R_PROTO != tcp ]]; then
    if rule_listening "$id" udp; then ok "UDP 端口 $id 正在监听"; else err "UDP 端口 $id 未监听"; fi
  fi
  for t in "$R_REMOTE" ${R_EXTRA_REMOTES//,/ } ${R_BACKUPS//,/ }; do
    split_hostport "$t" || continue
    if ms=$(tcp_probe "$HP_HOST" "$HP_PORT" 3); then ok "目标 $t 可达（${ms}ms）"; else err "目标 $t 不可达"; fi
  done
  x=$(fw_backend)
  if [[ $x == none ]]; then
    info "本机未启用防火墙（云厂商安全组仍需放行端口 $id 的 $(proto_label "$R_PROTO")）"
  else
    info "本机防火墙: $x（规则放行记录: $(if [[ -n $R_FW_OPENED && $R_FW_OPENED != 0 ]]; then echo "nxr 已放行 $(fw_merge "$R_FW_OPENED")"; else echo 未由 nxr 放行; fi)）"
  fi
  hr
  echo "  最近日志："
  svc_logs "$id" 20 | sed 's/^/    /'
  hr
  echo "  realm 配置："
  sed 's/^/    /' "$REALM_CONF_DIR/$id.toml" 2>/dev/null
}

menu_diag() {
  local id c
  title "规则诊断 / 日志"
  rules_brief || { pause; return; }
  echo
  pick_rule id || { pause; return; }
  while :; do
    rule_diag "$id"
    hr
    echo "  f. 实时日志（Ctrl+C 退出）   r. 重启该规则   回车 重新诊断   0. 返回"
    read_choice c
    case $c in
      f|F) trap ':' INT; svc_follow "$id"; trap - INT ;;
      r|R)
        rule_load "$id"
        if [[ $R_ENABLED != 1 ]]; then warn "规则已停用"; elif rule_start_verify "$id"; then ok "已重启"; fi
        pause ;;
      0) return ;;
    esac
  done
}

# ================================================================== 导入 / 备份
# 导入手工部署的 realm TOML：整体预检通过才停旧服务；任何一条失败都撤销已建规则并恢复旧服务
import_realm_toml() {
  local f=$1 rf line sec="" k v n=0 i use_udp=false no_tcp=false proto s pending="" sp=0 ap=0 tto="" uto="" dns="" fails=0 tmpd busy id
  local -a L R X B TH IFC LI LT RT bad=() svcs=() made=() pats=()
  local -A seenp=() was_en=() was_act=()
  [[ -f $f ]] || { err "文件不存在: $f"; return 1; }
  rf=$(readlink -f "$f" 2>/dev/null || echo "$f")
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%%#*}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    [[ -z $line ]] && continue
    if [[ -n $pending ]]; then
      pending+=" $line"
      [[ $line == *']'* ]] || continue
      line=$pending; pending=""
    elif [[ $line =~ ^[A-Za-z_]+[[:space:]]*=[[:space:]]*\[ && $line != *']'* ]]; then
      pending=$line; continue
    fi
    if [[ $line == '[[endpoints]]' ]]; then n=$((n + 1)); sec=ep; continue; fi
    if [[ $line =~ ^\[([A-Za-z_.]+)\]$ ]]; then sec=${BASH_REMATCH[1]}; continue; fi
    if [[ ! $line =~ ^([A-Za-z_]+)[[:space:]]*=[[:space:]]*(.*)$ ]]; then bad+=("$line"); continue; fi
    k=${BASH_REMATCH[1]}; v=${BASH_REMATCH[2]}
    v=${v#\"}; v=${v%\"}; v=${v#\'}; v=${v%\'}
    case "$sec:$k" in
      log:*|network:send_proxy_version|network:accept_proxy_timeout) ;;
      network:use_udp) use_udp=$v ;;
      network:no_tcp) no_tcp=$v ;;
      network:send_proxy) if [[ $v == true ]]; then sp=1; fi ;;
      network:accept_proxy) if [[ $v == true ]]; then ap=1; fi ;;
      network:tcp_timeout) tto=$v ;;
      network:udp_timeout) uto=$v ;;
      dns:mode) dns=$v ;;
      ep:listen) L[n]=$v ;;
      ep:remote) R[n]=$v ;;
      ep:extra_remotes) X[n]=${v//[\[\]\"\' ]/} ;;
      ep:balance) B[n]=$v ;;
      ep:through) TH[n]=$v ;;
      ep:interface) IFC[n]=$v ;;
      ep:listen_interface) LI[n]=$v ;;
      ep:listen_transport) LT[n]=$v ;;
      ep:remote_transport) RT[n]=$v ;;
      *) bad+=("[${sec:-顶层}] $k") ;;
    esac
  done < "$f"
  [[ $n -gt 0 ]] || { err "没有找到 [[endpoints]]（目前只支持 TOML 格式）"; return 1; }
  if [[ ${#bad[@]} -gt 0 ]]; then
    err "以下配置项暂不支持导入，为避免转发行为被改变已中止（未做任何改动，可用 nxr add 手动重建）："
    printf '      %s\n' "${bad[@]}" >&2
    return 1
  fi
  if [[ $no_tcp == true ]]; then proto=udp; elif [[ $use_udp == true ]]; then proto=both; else proto=tcp; fi

  tmpd=$(mktemp -d)
  for (( i = 1; i <= n; i++ )); do
    rule_reset
    if [[ ${L[i]:-} =~ ^\[(.*)\]:([0-9]+)$ || ${L[i]:-} =~ ^([^:]*):([0-9]+)$ ]]; then
      R_LISTEN_ADDR=${BASH_REMATCH[1]}; R_LISTEN_PORT=${BASH_REMATCH[2]}
    else
      err "无法解析监听地址: ${L[i]:-空}"; fails=$((fails + 1)); continue
    fi
    [[ -z $R_LISTEN_ADDR ]] && R_LISTEN_ADDR="0.0.0.0"
    R_REMOTE=${R[i]:-}; R_EXTRA_REMOTES=${X[i]:-}; R_BALANCE=${B[i]:-}; R_THROUGH=${TH[i]:-}; R_IFACE=${IFC[i]:-}
    R_LISTEN_IFACE=${LI[i]:-}; R_LISTEN_TRANSPORT=${LT[i]:-}; R_REMOTE_TRANSPORT=${RT[i]:-}; R_PROTO=$proto
    R_SEND_PROXY=$sp; R_ACCEPT_PROXY=$ap; R_TCP_TIMEOUT=$tto; R_UDP_TIMEOUT=$uto; R_DNS_MODE=$dns
    R_NAME="导入 ${f##*/}"
    rule_validate || { fails=$((fails + 1)); continue; }
    if rule_exists "$R_ID"; then err "端口 $R_ID 已有 nxr 规则"; fails=$((fails + 1)); continue; fi
    if [[ -n ${seenp[$R_ID]:-} ]]; then
      # 同一端口的 0.0.0.0 + [::] 两条（双栈写法）合并为一条 [::] 规则
      k=${seenp[$R_ID]}
      if [[ $(kv_get "$tmpd/$k" REMOTE) == "$R_REMOTE" && $(kv_get "$tmpd/$k" EXTRA_REMOTES) == "$R_EXTRA_REMOTES" ]] \
        && [[ $(kv_get "$tmpd/$k" LISTEN_ADDR) =~ ^(0\.0\.0\.0|::)$ && $R_LISTEN_ADDR =~ ^(0\.0\.0\.0|::)$ ]]; then
        sed -i 's/^LISTEN_ADDR=.*/LISTEN_ADDR=::/' "$tmpd/$k"
        continue
      fi
      err "端口 $R_ID 出现多次且目标不同，nxr 每个端口只能有一条规则"; fails=$((fails + 1)); continue
    fi
    seenp[$R_ID]=$i
    kv_save "$tmpd/$i" R_ "${RULE_KEYS[@]}"
  done
  if [[ $fails -gt 0 ]]; then rm -rf "$tmpd"; err "预检未通过，未做任何改动"; return 1; fi

  echo "  在 $f 中找到 $n 条转发（协议 $(proto_label "$proto")）："
  for (( i = 1; i <= n; i++ )); do printf '    %s → %s\n' "${L[i]}" "${R[i]}"; done
  if [[ $INIT == systemd ]]; then
    pats=(-e "$rf")
    if [[ $f == /* ]]; then pats+=(-e "$f"); fi
    for s in /etc/systemd/system/*.service /lib/systemd/system/*.service /usr/lib/systemd/system/*.service; do
      [[ -f $s && ${s##*/} != nxr@.service ]] || continue
      grep -E '^[[:space:]]*ExecStart=' "$s" | grep -i realm | grep -qF "${pats[@]}" || continue
      [[ " ${svcs[*]} " == *" ${s##*/} "* ]] || svcs+=("${s##*/}")
    done
  fi
  if [[ ${#svcs[@]} -gt 0 ]]; then
    warn "以下服务使用该配置，导入时会停止并禁用（配置文件保留不动）: ${svcs[*]}"
  else
    warn "没找到使用该配置的 systemd 服务；若 realm 由其他方式启动，请先手动停止，否则端口冲突会导致导入失败"
  fi
  confirm "确认导入?" Y || { rm -rf "$tmpd"; return 1; }
  if ! ensure_realm || ! svc_setup; then rm -rf "$tmpd"; return 1; fi

  for s in "${svcs[@]}"; do
    was_en[$s]=$(systemctl is-enabled "$s" 2>/dev/null)
    was_act[$s]=$(systemctl is-active "$s" 2>/dev/null)
    systemctl disable --now "$s" >/dev/null 2>&1 && info "已停止旧服务 $s"
  done
  for i in 1 2 3 4 5 6 7 8 9 10; do
    busy=0
    for k in "${!seenp[@]}"; do port_in_use "$k" && busy=1; done
    [[ $busy == 0 ]] && break
    sleep 0.5
  done
  for (( i = 1; i <= n; i++ )); do
    [[ -f $tmpd/$i ]] || continue
    rule_reset
    kv_load "$tmpd/$i" R_ "${RULE_KEYS[@]}"
    if rule_commit; then
      made+=("$R_ID")
    else
      # 启动失败时规则已写入（服务会不停重启），必须一并撤掉，否则会和恢复的旧服务抢端口
      if rule_exists "$R_ID"; then made+=("$R_ID"); fi
      fails=1; break
    fi
  done
  rm -rf "$tmpd"
  if [[ $fails -gt 0 ]]; then
    err "导入失败，正在撤销已导入的规则并恢复原服务"
    for id in "${made[@]}"; do rule_purge "$id"; done
    for s in "${svcs[@]}"; do
      [[ ${was_en[$s]} == enabled ]] && systemctl enable "$s" >/dev/null 2>&1
      [[ ${was_act[$s]} == active ]] && systemctl start "$s" >/dev/null 2>&1
      info "已恢复 $s（$(systemctl is-active "$s" 2>/dev/null)）"
    done
    watch_setup
    return 1
  fi
  ok "导入完成，共 ${#made[@]} 条规则"
  if [[ ${#svcs[@]} -gt 0 ]]; then info "如需退回旧方式：nxr del ${made[*]} -y && systemctl enable --now ${svcs[*]}"; fi
}

menu_import() {
  local f
  title "导入已有 realm 配置"
  echo "  适用于之前手动部署的 realm（如 /etc/realm/config.toml + realm.service）。"
  echo "  导入后每条转发变为独立的 nxr 规则，旧服务会被停止并禁用，原配置文件保留。"
  echo
  ask f "配置文件路径" "/etc/realm/config.toml" || return
  import_realm_toml "$f"
  pause
}

backup_create() {
  local f
  f="$BACKUP_DIR/nxr-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
  if tar -czf "$f" -C / "${NXR_DIR#/}" 2>/dev/null; then
    chmod 600 "$f"
    ok "已备份到 $f（包含节点 SSH 私钥，请妥善保管）"
  else
    err "备份失败"
    return 1
  fi
}

# backup_restore [备份文件]：不给文件时列出备份供选择（非交互时取最新的）
backup_restore() {
  local f=${1:-} id
  local -a files
  if [[ -z $f ]]; then
    mapfile -t files < <(ls -1t "$BACKUP_DIR"/nxr-backup-*.tar.gz 2>/dev/null)
    if [[ ${#files[@]} -eq 0 ]]; then
      ask f "备份文件路径" "" || return 1
    else
      local i=1
      for f in "${files[@]}"; do printf '    %d) %s\n' "$i" "$f"; i=$((i + 1)); done
      ask f "选择序号或输入路径" "1" || return 1
      if [[ $f =~ ^[0-9]+$ ]] && (( f >= 1 && f <= ${#files[@]} )); then f=${files[f-1]}; fi
    fi
  fi
  [[ -f $f ]] || { err "文件不存在: ${f:-未指定}"; return 1; }
  info "备份文件: $f"
  local tmpd added
  tmpd=$(mktemp -d)
  if ! tar -xzf "$f" -C "$tmpd" "${NXR_DIR#/}" 2>/dev/null || [[ ! -d $tmpd/${NXR_DIR#/}/rules ]]; then
    rm -rf "$tmpd"; err "不是有效的 nxr 备份"; return 1
  fi
  if ! confirm "恢复将替换当前全部规则/节点/链路配置，继续?" N; then rm -rf "$tmpd"; return 1; fi
  for id in $(rule_ids); do rule_purge "$id"; done
  rm -rf "$RULE_DIR" "$REALM_CONF_DIR" "$NODE_DIR" "$CHAIN_DIR"
  cp -a "$tmpd/${NXR_DIR#/}/." "$NXR_DIR/"
  rm -rf "$tmpd"
  load_global
  init_dirs
  # 防火墙放行状态属于原机器，按本机重新放行
  for id in $(rule_ids); do
    rule_load "$id" || continue
    R_FW_OPENED=0
    if [[ $R_ENABLED == 1 && $AUTO_FW == 1 ]] && added=$(fw_open "$id" "$R_PROTO"); then R_FW_OPENED=${added:-0}; fi
    rule_save
  done
  apply_all && ok "恢复完成"
}

export_cmds() {
  local id
  local -a a
  echo "#!/bin/bash"
  echo "# nxr 规则导出 $(date '+%F %T')，在新机器上执行即可重建"
  for id in $(rule_ids); do
    rule_load "$id" || continue
    a=(nxr add --listen "$(join_hostport "$R_LISTEN_ADDR" "$R_LISTEN_PORT")" --remote "$R_REMOTE" --proto "$R_PROTO")
    if [[ -n $R_NAME ]]; then a+=(--name "$R_NAME"); fi
    if [[ -n $R_EXTRA_REMOTES ]]; then a+=(--extra "$R_EXTRA_REMOTES" --balance "$R_BALANCE"); fi
    if [[ $R_HEALTH == 1 ]]; then a+=(--health); fi
    if [[ -n $R_ALLOW ]]; then a+=(--allow "$R_ALLOW"); fi
    if [[ -n $R_BACKUPS ]]; then a+=(--backup "$R_BACKUPS" --switchback "$R_SWITCHBACK"); fi
    if [[ -n $R_THROUGH ]]; then a+=(--through "$R_THROUGH"); fi
    if [[ -n $R_IFACE ]]; then a+=(--iface "$R_IFACE"); fi
    if [[ -n $R_LISTEN_IFACE ]]; then a+=(--listen-iface "$R_LISTEN_IFACE"); fi
    if [[ -n $R_LISTEN_TRANSPORT ]]; then a+=(--listen-transport "$R_LISTEN_TRANSPORT"); fi
    if [[ -n $R_REMOTE_TRANSPORT ]]; then a+=(--remote-transport "$R_REMOTE_TRANSPORT"); fi
    if [[ $R_SEND_PROXY == 1 ]]; then a+=(--send-proxy); fi
    if [[ $R_ACCEPT_PROXY == 1 ]]; then a+=(--accept-proxy); fi
    if [[ -n $R_DNS_MODE ]]; then a+=(--dns "$R_DNS_MODE"); fi
    if [[ -n $R_TCP_TIMEOUT ]]; then a+=(--tcp-timeout "$R_TCP_TIMEOUT"); fi
    if [[ -n $R_UDP_TIMEOUT ]]; then a+=(--udp-timeout "$R_UDP_TIMEOUT"); fi
    if [[ $R_ENABLED != 1 ]]; then a+=(--disable); fi
    a+=(--yes)
    printf '%q ' "${a[@]}"
    echo
  done
}

menu_backup() {
  local c f
  while :; do
    title "备份 / 恢复 / 导出"
    echo "  1. 创建备份（/root/nxr-backup-时间.tar.gz）"
    echo "  2. 从备份恢复"
    echo "  3. 导出规则为 nxr 命令（迁移到其他机器）"
    echo "  0. 返回"
    read_choice c
    case $c in
      1) backup_create; pause ;;
      2) backup_restore; pause ;;
      3)
        f="$BACKUP_DIR/nxr-rules-$(date +%Y%m%d-%H%M%S).sh"
        export_cmds | tee "$f"
        ok "已保存到 $f"
        pause ;;
      0|"") return ;;
    esac
  done
}

# ================================================================== 优化 / 设置
SYSCTL_ORIG="$NXR_DIR/sysctl.orig"

optimize_apply() {
  local cc=bbr fmax k
  modprobe tcp_bbr >/dev/null 2>&1
  if ! grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    warn "当前内核不支持 BBR（容器或旧内核），拥塞控制保持不变"
    cc=""
  fi
  fmax=$(sysctl -n fs.file-max 2>/dev/null)
  {
    echo "# 由 nxr 生成：转发节点网络优化（nxr 菜单「转发性能优化 → 还原」可恢复原值）"
    echo "net.core.default_qdisc = fq"
    if [[ -n $cc ]]; then echo "net.ipv4.tcp_congestion_control = $cc"; fi
    # 新版 systemd 已把 fs.file-max 设为极大值，只在更小时才调高
    if [[ $fmax =~ ^[0-9]{1,7}$ ]] && (( fmax < 1048576 )); then echo "fs.file-max = 1048576"; fi
    cat <<'EOF'
net.core.somaxconn = 32768
net.core.netdev_max_backlog = 32768
net.ipv4.tcp_max_syn_backlog = 32768
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_notsent_lowat = 16384
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 131072 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
EOF
  } > "$SYSCTL_FILE.new"
  if [[ ! -f $SYSCTL_ORIG ]]; then
    for k in $(awk -F' = ' '/^[a-z]/ {print $1}' "$SYSCTL_FILE.new"); do
      printf '%s = %s\n' "$k" "$(sysctl -n "$k" 2>/dev/null | tr '\t' ' ')"
    done > "$SYSCTL_ORIG"
  fi
  mv -f "$SYSCTL_FILE.new" "$SYSCTL_FILE"
  if sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1; then
    ok "已应用转发优化"
  else
    warn "部分参数在当前环境不可用（容器/OpenVZ 常见），其余已生效："
    sysctl -p "$SYSCTL_FILE" 2>&1 | grep -i -E 'error|denied|cannot|unknown' | sed 's/^/    /'
  fi
  printf '  拥塞控制: %s  队列: %s\n' "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" "$(sysctl -n net.core.default_qdisc 2>/dev/null)"
}

optimize_revert() {
  rm -f "$SYSCTL_FILE"
  if [[ -f $SYSCTL_ORIG ]]; then
    sysctl -p "$SYSCTL_ORIG" >/dev/null 2>&1
    rm -f "$SYSCTL_ORIG"
  fi
  sysctl --system >/dev/null 2>&1 || sysctl -p >/dev/null 2>&1
  ok "已还原转发优化（恢复为应用前的参数值）"
}

menu_optimize() {
  local c
  while :; do
    title "转发性能优化"
    printf '  拥塞控制 %s · 队列 %s · 可用算法 %s\n' "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" \
      "$(sysctl -n net.core.default_qdisc 2>/dev/null)" "$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null)"
    printf '  优化配置 %s\n' "$([[ -f $SYSCTL_FILE ]] && echo "已应用（$SYSCTL_FILE）" || echo 未应用)"
    hr
    echo "  1. 应用转发优化（BBR + fq + TCP 缓冲区 / 连接队列 / 端口范围）"
    echo "  2. 还原（删除优化配置）"
    echo "  0. 返回"
    read_choice c
    case $c in
      1) optimize_apply; pause ;;
      2) optimize_revert; pause ;;
      0|"") return ;;
    esac
  done
}

menu_settings() {
  local c v
  while :; do
    title "面板设置"
    printf '  1. realm 日志级别     %s\n' "$LOG_LEVEL"
    printf '  2. 自动放行防火墙     %s\n' "$([[ $AUTO_FW == 1 ]] && echo 开 || echo 关)"
    printf '  3. 默认监听地址       %s（当前解析为 %s）\n' "$DEFAULT_LISTEN" "$(default_listen_addr)"
    printf '  4. GitHub 下载加速    %s\n' "$GH_PROXY"
    printf '  5. realm 构建类型     %s\n' "$REALM_LIBC"
    echo "  0. 返回"
    read_choice c
    case $c in
      1)
        echo "    off / error / warn（默认）/ info（记录每个连接）/ debug"
        ask v "日志级别" "$LOG_LEVEL" || continue
        case $v in
          off|error|warn|info|debug|trace)
            LOG_LEVEL=$v; save_global
            if confirm "立即应用到全部规则（会重启规则）?" Y; then apply_all; fi ;;
          *) err "无效级别" ;;
        esac
        pause ;;
      2) if [[ $AUTO_FW == 1 ]]; then AUTO_FW=0; else AUTO_FW=1; fi; save_global ;;
      3)
        ask v "auto（有 IPv6 用 ::，否则 0.0.0.0）/ :: / 0.0.0.0 / 指定 IP" "$DEFAULT_LISTEN" || continue
        if [[ $v == auto ]] || is_ip "$v"; then DEFAULT_LISTEN=$v; save_global; else err "无效"; pause; fi ;;
      4)
        ask v "auto（直连失败自动换加速）/ none / 自定义前缀如 https://ghfast.top/" "$GH_PROXY" || continue
        if [[ $v == auto || $v == none || $v =~ ^https?://[A-Za-z0-9./_-]+$ ]]; then GH_PROXY=$v; save_global; else err "无效"; pause; fi ;;
      5) if [[ $REALM_LIBC == musl ]]; then REALM_LIBC=gnu; else REALM_LIBC=musl; fi; save_global ;;
      0|"") return ;;
    esac
  done
}

# ================================================================== 安装 / 更新 / 卸载
# 下载的脚本是否完整可用（最后一行必须是入口调用）
script_ok() {
  grep -q '^NXR_VERSION=' "$1" && bash -n "$1" 2>/dev/null && [[ $(tail -n 1 "$1") == 'main "$@"' ]]
}

# self_install [--force]：安装为快捷命令；不会用旧版本覆盖已安装的新版本（--force 除外）
self_install() {
  local src=${BASH_SOURCE[0]} tmp cur force=0
  [[ ${1:-} == --force ]] && force=1
  cur=$(grep -m1 '^NXR_VERSION=' "$NXR_BIN" 2>/dev/null | cut -d'"' -f2)
  if [[ -f $src && -r $src ]]; then
    [[ $src -ef $NXR_BIN ]] && return 0
    cmp -s "$src" "$NXR_BIN" 2>/dev/null && return 0
    if [[ $force != 1 && -n $cur ]] && ver_gt "$cur" "$NXR_VERSION"; then
      warn "已安装的 nxr $cur 比当前脚本 $NXR_VERSION 新，未覆盖（确需降级: bash $src install --force）"
      return 0
    fi
    install -m 755 "$src" "$NXR_BIN" && info "已安装快捷命令 nxr $NXR_VERSION（$NXR_BIN）"
    return 0
  fi
  if [[ -n $cur ]] && ! ver_gt "$NXR_VERSION" "$cur"; then return 0; fi
  tmp=$(mktemp)
  if gh_dl "$NXR_RAW_URL" "$tmp" 60 && script_ok "$tmp"; then
    install -m 755 "$tmp" "$NXR_BIN" && info "已安装快捷命令 nxr（$NXR_BIN）"
  else
    warn "快捷命令安装失败：无法下载 $NXR_RAW_URL（可手动保存脚本到 $NXR_BIN 并 chmod +x）"
  fi
  rm -f "$tmp"
  [[ -x $NXR_BIN ]]
}

nxr_update() {
  local tmp newv
  tmp=$(mktemp)
  info "下载最新版 nxr"
  if ! gh_dl "$NXR_RAW_URL" "$tmp" 60; then rm -f "$tmp"; err "下载失败"; return 1; fi
  if ! script_ok "$tmp"; then rm -f "$tmp"; err "下载内容不完整或校验失败，未更新"; return 1; fi
  newv=$(grep -m1 '^NXR_VERSION=' "$tmp" | cut -d'"' -f2)
  if [[ ${1:-} != --force ]] && ver_gt "$NXR_VERSION" "$newv"; then
    rm -f "$tmp"; ok "本机 nxr $NXR_VERSION 比远端 $newv 新，未更新"; return 0
  fi
  if ! install -m 755 "$tmp" "$NXR_BIN"; then rm -f "$tmp"; err "写入 $NXR_BIN 失败"; return 1; fi
  rm -f "$tmp"
  "$NXR_BIN" init --quiet >/dev/null 2>&1
  ok "nxr 已更新：$NXR_VERSION → $newv（远程节点会在下次部署/同步时自动更新）"
}

# 除 nxr 以外仍在使用 realm 程序的服务
realm_users() {
  local f found=""
  for f in /etc/systemd/system/*.service /lib/systemd/system/*.service /usr/lib/systemd/system/*.service /etc/init.d/*; do
    [[ -f $f ]] || continue
    case ${f##*/} in nxr@.service|nxr-watch.service|nxr|nxr.*) continue ;; esac
    grep -qsF "$REALM_BIN" "$f" && found+="${found:+ }${f##*/}"
  done
  echo "$found"
}

nxr_uninstall() {
  local id users
  title "卸载 nxr"
  if [[ $(chain_count) -gt 0 ]]; then
    warn "本机还有 $(chain_count) 条链路记录，卸载不会清理远程节点上的规则（需要的话先执行 nxr chain del <ID>）"
  fi
  confirm "确认卸载 nxr 并删除本机全部转发规则?" N || return 1
  for id in $(rule_ids); do rule_purge "$id"; done
  case $INIT in
    systemd)
      systemctl disable --now nxr-watch.timer >/dev/null 2>&1
      rm -f "$SYSTEMD_UNIT" "$WATCH_SERVICE" "$WATCH_TIMER"
      systemctl daemon-reload ;;
    openrc)
      rm -f "$OPENRC_SCRIPT" /etc/init.d/nxr.*
      if [[ -f /etc/crontabs/root ]]; then sed -i '/nxr watch/d' /etc/crontabs/root; fi ;;
  esac
  if has nft; then
    nft delete table inet "$ACCT_TABLE" >/dev/null 2>&1
    nft delete table inet "$ACL_TABLE" >/dev/null 2>&1
  fi
  acct_ipt_remove_all
  if [[ -f $SYSCTL_FILE ]]; then
    if confirm_opt "还原转发优化（$SYSCTL_FILE）?" N; then optimize_revert; else info "保留转发优化 $SYSCTL_FILE"; fi
  fi
  if [[ -x $REALM_BIN ]]; then
    users=$(realm_users)
    if [[ -n $users ]]; then
      info "保留 realm 程序 $REALM_BIN：仍被这些服务使用 $users"
    elif [[ $REALM_OWNED != 1 ]]; then
      info "保留 realm 程序 $REALM_BIN（不是 nxr 安装的）"
    elif confirm_opt "删除 realm 程序 $REALM_BIN?" N; then
      rm -f "$REALM_BIN"
    else
      info "保留 realm 程序 $REALM_BIN"
    fi
  fi
  if confirm_opt "删除配置目录 $NXR_DIR（含节点、链路记录和 SSH 密钥）和日志 $LOG_DIR?" N; then
    rm -rf "$NXR_DIR" "$LOG_DIR"
  elif [[ -d $NXR_DIR ]]; then
    info "已保留 $NXR_DIR（节点、链路记录和 SSH 密钥）和日志，彻底清理: rm -rf $NXR_DIR $LOG_DIR"
  fi
  rm -rf "$CACHE_DIR" "$LOCK_FILE"
  rm -f "$NXR_BIN"
  ok "nxr 已卸载"
  exit 0
}

# ================================================================== 主菜单
menu_main() {
  local c rv total running id
  while :; do
    rv=$(realm_version)
    states_load
    total=0; running=0
    for id in "${!ST[@]}"; do
      total=$((total + 1))
      [[ ${ST[$id]} == active ]] && running=$((running + 1))
    done
    clear_screen
    printf '\n  %sNXR · Realm 转发面板%s  v%s        %s快捷命令: nxr%s\n' "$C_CYN$C_BLD" "$C_RST" "$NXR_VERSION" "$C_YLW" "$C_RST"
    printf '  %s一个前置 · 多个 IX · 多个出口 多节点链路管理%s\n' "$C_GRY" "$C_RST"
    hr
    printf '  realm %s · 规则 %s（运行 %s）· 节点 %s · 链路 %s · %s\n' \
      "$([[ -n $rv ]] && echo "${C_GRN}v$rv$C_RST" || echo "${C_RED}未安装$C_RST")" \
      "$total" "$running" "$(node_count)" "$(chain_count)" "$INIT"
    hr
    echo "   1. 安装 / 更新 realm"
    echo "   2. 添加转发规则"
    echo "   3. 规则列表（状态 / 连接数 / 流量）"
    echo "   4. 修改规则"
    echo "   5. 删除规则"
    echo "   6. 启用 / 停用规则"
    echo "   7. 重启规则"
    printf '  %s── IX 链路 ──%s\n' "$C_GRY" "$C_RST"
    echo "   8. 创建转发链路（前置 → IX → 出口，支持多 IX / 多出口）"
    echo "   9. 链路管理（拓扑总览 / 批量开线路 / 检测 / 删除）"
    echo "  10. 节点管理（SSH 多节点）"
    printf '  %s── 工具 ──%s\n' "$C_GRY" "$C_RST"
    echo "  11. 连通性 / 延迟测试"
    echo "  12. 规则诊断 / 日志"
    echo "  13. 导入已有 realm 配置"
    echo "  14. 备份 / 恢复 / 导出"
    echo "  15. 转发性能优化（BBR / 内核参数）"
    echo "  16. 面板设置"
    hr
    echo "  88. 更新 nxr        99. 卸载 nxr        0. 退出"
    read_choice c
    case $c in
      1) menu_realm ;;
      2) menu_add ;;
      3) menu_list ;;
      4) menu_edit ;;
      5) menu_delete ;;
      6) menu_toggle ;;
      7) menu_restart ;;
      8) chain_wizard; pause ;;
      9) menu_chains ;;
      10) menu_nodes ;;
      11) menu_probe ;;
      12) menu_diag ;;
      13) menu_import ;;
      14) menu_backup ;;
      15) menu_optimize ;;
      16) menu_settings ;;
      88) nxr_update; pause ;;
      99) nxr_uninstall ;;
      0) exit 0 ;;
    esac
  done
}

# ================================================================== 命令行
usage() {
  cat <<EOF
NXR · Realm 转发管理面板 v$NXR_VERSION

用法: nxr [命令] [参数]      不带参数进入交互菜单

规则
  add  --port P --remote HOST:PORT [选项]   添加规则（--listen [::]:P 可指定监听地址）
  edit <端口> [选项]                         修改规则（只覆盖给出的选项，值为 - 表示清空）
  del  <端口>... [--chain ID] [-y]           删除规则
  list [--raw]                               规则列表（状态/连接/流量）
  show <端口>                                规则详情
  enable|disable <端口>                      启用/停用
  restart <端口|all>                         重启（已停用的规则不会被启动）
  log <端口> [-f]                            查看日志
  export                                     导出为 nxr 命令
  import-realm [文件] [-y]                   导入已有 realm TOML 配置

规则选项
  --proto both|tcp|udp      --name 名称            --through 出站源IP
  --iface 出站网卡          --listen-iface 入站网卡
  --extra H:P,H:P --balance roundrobin|iphash[: 权重] [--health]   负载均衡（--health 自动摘除故障目标）
  --backup H:P,H:P [--switchback 0|1]                  主备切换（自动探测，与负载均衡二选一）
  --listen-transport 参数   --remote-transport 参数     加密传输（tls/ws/wss）
  --send-proxy  --accept-proxy   --dns ipv4_only|ipv6_only|ipv4_then_ipv6|...
  --allow IP,IP/前缀              来源 IP 白名单（其余来源一律丢弃，- 表示取消）
  --disable  --no-fw  --force  -y

链路与节点（一个前置 · 多个 IX · 多个出口）
  chain create                               交互式单条链路向导
  chain batch                                批量开线路向导（一前置 × 多 IX × 多出口）
  chain add --hop 节点:端口 --hop 节点:端口[@地址][%网卡][,节点:端口...]... --target [节点=]主机:端口[,...]
            [--mode failover|roundrobin|iphash] [--target-mode 同上] [--no-acl 不给 IX 跳加来源白名单]
            [--name 名称] [--proto both|tcp|udp] [--transport none|tls|ws|wss] [--sni 域名]
            [--ws-host 域名] [--ws-path /路径] [-y]
            一跳写多个成员 = 多台 IX 共同承担；--target 写多个 = 多台出口；节点=地址 表示该 IX 专用的出口地址
            iphash（按来源 IP 分流）只在前置这一跳有效，之后各跳自动改用轮询
  chain topo | list | show ID | check [ID|all]               拓扑/列表/详情/逐跳检测
  chain del ID [-y] [--force]                 删除链路并清理各节点规则（--force：节点失联也删除记录）
  node  [list|test [名称]|add 名称 主机 [--port --user --key --jump --addr --note]|key 名称|sync 名称]
  node del 名称 [--force]                    删除节点（仍被链路/跳板引用时需 --force）

工具
  probe <主机> <端口> [次数]                 TCP 延迟测试
  install-realm [--version vX] [--file 路径] [--libc musl|gnu] [--force]
  optimize [--revert]                        应用 / 还原转发网络优化
  install                                    把当前脚本安装为快捷命令 nxr
  backup | restore [文件] [-y]               备份到 /root / 从备份恢复（不指定文件时用最新的）
  uninstall [-y] [--purge]                   卸载（-y 保留配置目录、realm 和网络优化；--purge 一并清除）
  update [--force] | version

示例
  nxr add --port 11111 --remote 203.0.113.10:22222
  nxr add --port 22222 --remote 10.0.0.1:33333 --iface eth1 --name IX入口
  nxr add --port 443 --remote a.com:443 --backup b.com:443,c.com:443
  nxr chain add --hop local:11111 --hop ix-gz:22222@203.0.113.10 --target 10.0.0.1:33333
  nxr chain add --hop local:11112 --hop ix-a:22222,ix-b:22222 --target 10.0.0.1:33333 --mode roundrobin
EOF
}

cli_add() {
  rule_reset
  parse_rule_opts "$@" || return 2
  [[ -n $R_LISTEN_PORT ]] || { err "缺少 --port"; return 2; }
  [[ -n $R_REMOTE ]] || { err "缺少 --remote"; return 2; }
  local rc
  rule_commit
  rc=$?
  if [[ $rc -eq 5 && $COMMIT_RESTORED != 1 && ( ! -t 0 || $ASSUME_YES == 1 ) ]]; then
    rule_purge "$R_ID"
    warn "启动失败，已回滚规则 $R_ID"
  fi
  return "$rc"
}

cli_edit() {
  local id=${1:-}
  [[ -n $id ]] || { err "用法: nxr edit <端口> [选项]"; return 2; }
  shift
  rule_load "$id" || { err "规则不存在: $id"; return 1; }
  parse_rule_opts "$@" || return 2
  rule_commit "$id"
}

cli_del() {
  local chain="" id cs
  local -a ids=()
  while [[ $# -gt 0 ]]; do
    case $1 in
      --chain) chain=${2:-}; shift; [[ $# -gt 0 ]] && shift ;;
      -y|--yes) ASSUME_YES=1; shift ;;
      *) ids+=("$1"); shift ;;
    esac
  done
  [[ ${#ids[@]} -gt 0 ]] || { err "用法: nxr del <端口>... [--chain ID] [-y]"; return 2; }
  for id in "${ids[@]}"; do
    if ! rule_exists "$id"; then info "规则 $id 不存在，跳过"; continue; fi
    if [[ -n $chain ]]; then
      cs=$(kv_get "$(rule_path "$id")" CHAIN)
      if [[ $cs != "$chain" ]]; then warn "规则 $id 不属于链路 $chain，跳过"; continue; fi
    fi
    confirm "删除规则 $id?" Y || continue
    rule_purge "$id" && ok "已删除规则 $id"
  done
  watch_setup
  return 0
}

cli_status() {
  local id="" a
  for a in "$@"; do [[ $a == --raw ]] || id=$a; done
  if [[ -n $id ]]; then
    if ! rule_exists "$id"; then echo missing; return 1; fi
    rule_load "$id"
    if [[ $R_ENABLED != 1 ]]; then echo disabled; return 0; fi
    svc_state "$id"
    return 0
  fi
  rules_table
}

cli_list() {
  local id
  if [[ ${1:-} == --raw ]]; then
    states_load
    for id in $(rule_ids); do
      rule_load "$id" || continue
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$R_ENABLED" "${ST[$id]:-inactive}" \
        "$(join_hostport "$R_LISTEN_ADDR" "$R_LISTEN_PORT")" "$(rule_target)" "$R_PROTO" "${R_CHAIN:--}" "$R_NAME"
    done
    return 0
  fi
  rules_table
}

cli_probe() {
  local raw=0 a host port count=4 ms
  local -a pos=()
  for a in "$@"; do if [[ $a == --raw ]]; then raw=1; else pos+=("$a"); fi; done
  if [[ ${#pos[@]} -ge 1 ]] && split_hostport "${pos[0]}"; then
    host=$HP_HOST; port=$HP_PORT; count=${pos[1]:-4}
  else
    host=${pos[0]:-}; port=${pos[1]:-}; count=${pos[2]:-4}
  fi
  host=${host#[}; host=${host%]}
  if ! is_host "$host" || ! is_port "$port"; then err "用法: nxr probe <主机> <端口> [次数]"; return 2; fi
  is_uint "$count" || count=4
  if [[ $raw == 1 ]]; then
    if ms=$(tcp_probe "$host" "$port" 3); then echo "ok $ms"; return 0; fi
    echo "fail"
    return 1
  fi
  tcping "$host" "$port" "$count"
}

cli_port_check() {
  local p=${1:-}
  is_port "$p" || { echo "端口无效"; return 1; }
  if rule_exists "$p"; then echo "端口 $p 已有 nxr 规则"; return 1; fi
  if port_in_use "$p"; then echo "端口 $p 已被占用: $(port_owner "$p")"; return 1; fi
  echo free
}

cli_hop_check() {
  local p=${1:-} h=${2:-} hp=${3:-} st ms
  if rule_exists "$p"; then
    rule_load "$p"
    if [[ $R_ENABLED == 1 ]]; then st=$(svc_state "$p"); else st=disabled; fi
  else
    st=missing
  fi
  if ms=$(tcp_probe "$h" "$hp" 3); then echo "$st ok $ms"; else echo "$st fail -"; fi
}

cli_node() {
  local sub=${1:-list} n
  [[ $# -gt 0 ]] && shift
  case $sub in
    list)
      for n in $(node_names); do node_load "$n"; printf '%-14s %s\n' "$n" "$(node_label)"; done ;;
    test)
      if [[ -n ${1:-} ]]; then node_test "$1"; else for n in $(node_names); do node_test "$n"; done; fi ;;
    add)
      node_reset
      N_NAME=${1:-}; N_HOST=${2:-}
      shift 2 2>/dev/null || { err "用法: nxr node add 名称 主机 [--port --user --key --jump --addr --note]"; return 2; }
      while [[ $# -gt 0 ]]; do
        case $1 in
          --port) N_PORT=${2:-} ;;
          --user) N_USER=${2:-} ;;
          --key) N_KEY=${2:-} ;;
          --jump) N_JUMP=${2:-} ;;
          --addr) N_ADDR=${2:-} ;;
          --note) N_NOTE=${2:-} ;;
          *) err "未知参数: $1"; return 2 ;;
        esac
        shift; [[ $# -gt 0 ]] && shift
      done
      [[ -z $N_ADDR ]] && N_ADDR=$N_HOST
      if [[ -z $N_KEY ]]; then ensure_nxr_key && N_KEY=$NXR_KEY; fi
      if ! is_name "$N_NAME" || [[ $N_NAME == local ]] || ! is_host "$N_HOST" || ! is_port "$N_PORT" || ! is_host "$N_ADDR" || ! is_text "$N_NOTE"; then
        err "参数无效"; return 2
      fi
      if [[ -n $N_JUMP && ! -f $(node_path "$N_JUMP") ]]; then err "跳板节点不存在: $N_JUMP"; return 2; fi
      node_save
      ok "节点 $N_NAME 已保存"
      node_test "$N_NAME" ;;
    del)
      [[ -f $(node_path "${1:-}") ]] || { err "节点不存在"; return 1; }
      if [[ ${2:-} != --force ]]; then node_unused "$1" || return 1; fi
      rm -f "$(node_path "$1")"; ok "已删除节点 $1" ;;
    key) node_copy_key "${1:-}" ;;
    sync) node_prepare "${1:-}" ;;
    *) err "未知子命令: $sub"; return 2 ;;
  esac
}

# nxr chain add --hop 节点:端口[,节点:端口...] ... --target [节点=]主机:端口[,...]
#   跳成员写法 节点:端口[@上一跳连接地址][%出站网卡]；一跳写多个成员即多 IX
cli_chain_add() {
  local cname="" proto=both tmode=none sni="www.bing.com" wshost="www.bing.com" wspath="/nxr" spec m n=0 i k node port addr iface out cid x
  local -a hops=() members=() ms=() last=() xs=() tn=() tp=()
  local -a H_SPEC=()
  local -A seen=() prepared=()
  C_MODE=failover; C_TMODE=""; C_TARGETS=""; C_ACL=1
  while [[ $# -gt 0 ]]; do
    case $1 in
      --name|--proto|--transport|--sni|--ws-host|--ws-path|--hop|--target|--mode|--target-mode)
        [[ $# -ge 2 ]] || { err "参数 $1 缺少值"; return 2; } ;;&
      --name) cname=$2; shift ;;
      --proto) proto=$2; shift ;;
      --transport) tmode=$2; shift ;;
      --sni) sni=$2; shift ;;
      --ws-host) wshost=$2; shift ;;
      --ws-path) wspath=$2; shift ;;
      --hop) hops+=("${2// /}"); shift ;;
      --target) C_TARGETS+="${C_TARGETS:+,}${2// /}"; shift ;;
      --mode) C_MODE=$2; shift ;;
      --target-mode) C_TMODE=$2; shift ;;
      --no-acl) C_ACL=0 ;;
      -y|--yes) ASSUME_YES=1 ;;
      *) err "未知参数: $1"; return 2 ;;
    esac
    shift
  done
  [[ -n $C_TMODE ]] || C_TMODE=$C_MODE
  if [[ ${#hops[@]} -lt 1 || -z $C_TARGETS ]]; then
    err "用法: nxr chain add --hop 节点:端口 [--hop 节点:端口,节点:端口]... --target [节点=]主机:端口[,...] [--mode failover|roundrobin|iphash]"
    return 2
  fi
  case $proto in both|tcp|udp) ;; *) err "协议无效: $proto"; return 2 ;; esac
  case $tmode in none|tls|ws|wss) ;; *) err "传输方式无效: $tmode"; return 2 ;; esac
  if ! valid_mode "$C_MODE" || ! valid_mode "$C_TMODE"; then err "分流方式只能是 failover / roundrobin / iphash"; return 2; fi
  cid=$(chain_next_id)
  [[ -z $cname ]] && cname=$cid
  if ! is_text "$cname" || [[ ${#cname} -gt 58 ]]; then err "名称无效（最多 58 个字符，不能含 |）"; return 2; fi
  for spec in "${hops[@]}"; do
    n=$((n + 1))
    members=()
    IFS=, read -ra ms <<<"$spec"
    for m in "${ms[@]}"; do
      [[ -z $m ]] && continue
      iface=""; addr=""
      if [[ $m == *%* ]]; then iface=${m##*%}; m=${m%\%*}; fi
      if [[ $m == *@* ]]; then addr=${m#*@}; m=${m%%@*}; fi
      [[ $m == *:* ]] || { err "跳成员格式无效: $m（应为 节点:端口）"; return 2; }
      node=${m%%:*}; port=${m##*:}
      node_exists "$node" || { err "节点不存在: $node"; return 2; }
      is_port "$port" || { err "端口无效: $port"; return 2; }
      if [[ -n $iface ]] && ! is_iface "$iface"; then err "网卡名无效: $iface"; return 2; fi
      if [[ -n ${seen[$node:$port]+x} ]]; then err "节点 $node 的端口 $port 重复使用"; return 2; fi
      if [[ -n $addr ]] && ! is_host "$addr"; then err "地址无效: $addr"; return 2; fi
      seen[$node:$port]=1
      if [[ $n -gt 1 ]]; then
        if [[ -z $addr ]]; then
          if [[ $node == local ]]; then
            addr=$(public_ipv4) || { err "无法获取本机地址，请用 local:端口@地址 指定"; return 2; }
          else
            addr=$(kv_get "$(node_path "$node")" ADDR)
            [[ -n $addr ]] || addr=$(kv_get "$(node_path "$node")" HOST)
          fi
        fi
        is_host "$addr" || { err "地址无效: $addr"; return 2; }
      fi
      members+=("$node|$port|$addr|$iface|")
    done
    [[ ${#members[@]} -gt 0 ]] || { err "第 $n 跳没有成员"; return 2; }
    H_SPEC[n]=$(IFS=';'; echo "${members[*]}")
  done
  tier_parse "${H_SPEC[n]}"
  last=("${M_NODE[@]}")
  IFS=, read -ra xs <<<"$C_TARGETS"
  for x in "${xs[@]}"; do
    if [[ $x == *=* ]]; then
      [[ " ${last[*]} " == *" ${x%%=*} "* ]] || { err "出口 $x 指定的节点不在最后一跳"; return 2; }
      split_hostport "${x#*=}" || { err "出口地址无效: $x"; return 2; }
    else
      split_hostport "$x" || { err "出口地址无效: $x"; return 2; }
    fi
  done
  for x in "${last[@]}"; do
    [[ -n $(targets_for "$x" "$C_TARGETS") ]] || { err "节点 $x 没有可用的出口地址"; return 2; }
  done
  TL_LISTEN=""; TL_REMOTE=""
  if [[ $tmode != none ]]; then
    [[ $n -gt 1 ]] || { err "单跳链路没有跳间传输，无需加密"; return 2; }
    [[ $proto != udp ]] || { err "仅 UDP 的链路不支持加密传输"; return 2; }
    transport_build "$tmode" "$sni" "$wshost" "$wspath"
    if ! is_transport "$TL_LISTEN" || ! is_transport "$TL_REMOTE"; then err "传输参数含非法字符"; return 2; fi
  fi
  for (( i = 1; i <= n; i++ )); do
    tier_parse "${H_SPEC[i]}"
    tn=("${M_NODE[@]}"); tp=("${M_PORT[@]}")
    for k in "${!tn[@]}"; do
      if [[ -z ${prepared[${tn[k]}]+x} ]]; then
        node_prepare "${tn[k]}" || return 1
        prepared[${tn[k]}]=1
      fi
      if ! out=$(node_nxr "${tn[k]}" port-check "${tp[k]}" 2>&1); then err "[${tn[k]}] $out"; return 1; fi
    done
  done
  chain_deploy "$cid" "$cname" "$proto" "$tmode" "$n"
}

cli_chain() {
  local sub=${1:-list}
  [[ $# -gt 0 ]] && shift
  case $sub in
    list) chain_table ;;
    topo) chain_topo ;;
    show) chain_show "${1:-}" ;;
    check) chain_check_any "${1:-all}" ;;
    add) cli_chain_add "$@" ;;
    batch) chain_batch_wizard ;;
    del|delete)
      local a cid=""
      for a in "$@"; do
        case $a in -y|--yes) ASSUME_YES=1 ;; --force) OPT_FORCE=1 ;; *) cid=$a ;; esac
      done
      [[ -n $cid ]] || { err "用法: nxr chain del <链路ID> [-y] [--force]"; return 2; }
      confirm "删除链路 $cid 并清理各节点规则?" N && chain_delete "$cid" ;;
    create|new) chain_wizard ;;
    *) err "未知子命令: $sub"; return 2 ;;
  esac
}

# 节点侧：本跳服务状态 + 到地址池每个成员的连通性（供控制机做链路检测）
cli_pool_check() {
  local p=${1:-} pool=${2:-} st x ms
  local -a xs
  if rule_exists "$p"; then
    rule_load "$p"
    if [[ $R_ENABLED == 1 ]]; then st=$(svc_state "$p"); else st=disabled; fi
  else
    st=missing
  fi
  echo "$st"
  IFS=, read -ra xs <<<"$pool"
  for x in "${xs[@]}"; do
    [[ -z $x ]] && continue
    if split_hostport "$x" && ms=$(tcp_probe "$HP_HOST" "$HP_PORT" 3); then echo "$x ok $ms"; else echo "$x fail -"; fi
  done
}

# 节点侧：已被占用的端口（正在监听的 + 已有 nxr 规则的），供批量分配端口
cli_used_ports() {
  { ssq -lntu | awk '{n = split($5, a, ":"); print a[n]}'; rule_ids; } | grep -E '^[0-9]+$' | sort -un
}

parse_rule_opts() {
  local o v
  while [[ $# -gt 0 ]]; do
    o=$1
    shift
    v=""
    case $o in
      -p|--port|-l|--listen|-r|--remote|--extra|--balance|--backup|--switchback|--proto|--through|--iface|--listen-iface|--listen-transport|--remote-transport|--dns|--tcp-timeout|--udp-timeout|-n|--name|--chain|--role|--allow)
        [[ $# -gt 0 ]] || { err "参数 $o 缺少值"; return 2; }
        v=$1
        shift
        [[ $v == - ]] && v="" ;;&
      -p|--port) R_LISTEN_PORT=$v ;;
      -l|--listen)
        if [[ $v =~ ^[0-9]+$ ]]; then
          R_LISTEN_PORT=$v
        elif [[ $v =~ ^\[([0-9A-Fa-f:.]+)\]:([0-9]+)$ || $v =~ ^([0-9.]+):([0-9]+)$ ]]; then
          R_LISTEN_ADDR=${BASH_REMATCH[1]}; R_LISTEN_PORT=${BASH_REMATCH[2]}
        else
          err "监听格式无效: $v（示例 11111 / 0.0.0.0:11111 / [::]:11111）"; return 2
        fi ;;
      -r|--remote) R_REMOTE=$v ;;
      --extra) R_EXTRA_REMOTES=$v ;;
      --balance) R_BALANCE=$v ;;
      --backup) R_BACKUPS=$v ;;
      --switchback) R_SWITCHBACK=$v ;;
      --proto) R_PROTO=$v ;;
      --tcp) R_PROTO=tcp ;;
      --udp) R_PROTO=udp ;;
      --through) R_THROUGH=$v ;;
      --iface) R_IFACE=$v ;;
      --listen-iface) R_LISTEN_IFACE=$v ;;
      --listen-transport) R_LISTEN_TRANSPORT=$v ;;
      --remote-transport) R_REMOTE_TRANSPORT=$v ;;
      --health) R_HEALTH=1 ;;
      --allow) R_ALLOW=${v// /} ;;
      --no-health) R_HEALTH=0; R_DOWN="" ;;
      --send-proxy) R_SEND_PROXY=1 ;;
      --no-send-proxy) R_SEND_PROXY=0 ;;
      --accept-proxy) R_ACCEPT_PROXY=1 ;;
      --no-accept-proxy) R_ACCEPT_PROXY=0 ;;
      --dns) R_DNS_MODE=$v ;;
      --tcp-timeout) R_TCP_TIMEOUT=$v ;;
      --udp-timeout) R_UDP_TIMEOUT=$v ;;
      -n|--name) R_NAME=$v ;;
      --chain) R_CHAIN=$v ;;
      --role) R_ROLE=$v ;;
      --disable|--disabled) R_ENABLED=0 ;;
      --enable) R_ENABLED=1 ;;
      --no-fw) OPT_NO_FW=1 ;;
      --force) OPT_FORCE=1 ;;
      -y|--yes) ASSUME_YES=1 ;;
      -q|--quiet) QUIET=1 ;;
      *) err "未知参数: $o"; return 2 ;;
    esac
  done
  return 0
}

main() {
  local cmd=${1:-}
  [[ $# -gt 0 ]] && shift
  case $cmd in
    version|-v|--version)
      if [[ ${1:-} == --raw ]]; then echo "$NXR_VERSION"; else echo "nxr $NXR_VERSION"; fi
      return 0 ;;
    help|-h|--help) usage; return 0 ;;
  esac
  need_root
  detect_init
  load_global
  init_dirs
  case $cmd in
    "")
      if [[ ! -t 0 ]]; then exec </dev/tty || die "请在交互终端中运行：bash <(curl -sL 地址)"; fi
      ensure_base_deps
      self_install >/dev/null 2>&1
      menu_main ;;
    init)
      ensure_base_deps >/dev/null 2>&1
      svc_setup >/dev/null 2>&1 || { err "初始化失败：需要 systemd 或 OpenRC"; return 1; }
      [[ ${1:-} == --quiet ]] || ok "初始化完成（$INIT）" ;;
    add) cli_add "$@" ;;
    edit) cli_edit "$@" ;;
    del|rm|delete) cli_del "$@" ;;
    list|ls) cli_list "$@" ;;
    show) rule_detail "${1:-}" ;;
    status) cli_status "$@" ;;
    enable) rule_set_enabled "${1:-}" 1 ;;
    disable) rule_set_enabled "${1:-}" 0 ;;
    restart)
      if [[ ${1:-all} == all ]]; then
        apply_all
      else
        rule_load "$1" || { err "规则不存在: $1"; return 1; }
        if [[ $R_ENABLED != 1 ]]; then warn "规则 $1 已停用，未重启（启用: nxr enable $1）"; return 1; fi
        rule_start_verify "$1" && ok "规则 $1 已重启"
      fi ;;
    log|logs)
      rule_exists "${1:-}" || { err "规则不存在: ${1:-}"; return 1; }
      if [[ ${2:-} == -f ]]; then svc_follow "$1"; else svc_logs "$1" 50; fi ;;
    probe|ping) cli_probe "$@" ;;
    install-realm)
      local -a ra=()
      while [[ $# -gt 0 ]]; do
        case $1 in -y|--yes) ASSUME_YES=1 ;; --auto) ;; *) ra+=("$1") ;; esac
        shift
      done
      ensure_base_deps
      realm_install "${ra[@]}" ;;
    realm-version) realm_version || echo none ;;
    apply) apply_all ;;
    acct-sync)
      if [[ ${1:-} == --port && -n ${2:-} ]]; then
        with_lock acct_add "$2"
        with_lock acl_sync_port "$2"
      else
        with_lock acct_sync_all
      fi ;;
    src-ips) cli_src_ips ;;
    watch) watch_run ;;
    ifaces) local_ifaces ;;
    random-port) random_free_port ;;
    port-check) cli_port_check "$@" ;;
    hop-check) cli_hop_check "$@" ;;
    pool-check) cli_pool_check "$@" ;;
    used-ports) cli_used_ports ;;
    topo) chain_topo ;;
    import-realm)
      local f=/etc/realm/config.toml a
      for a in "$@"; do case $a in -y|--yes) ASSUME_YES=1 ;; *) f=$a ;; esac; done
      import_realm_toml "$f" ;;
    export) export_cmds ;;
    backup) backup_create ;;
    restore)
      local bf="" ba
      for ba in "$@"; do case $ba in -y|--yes) ASSUME_YES=1 ;; -*) err "未知参数: $ba"; return 2 ;; *) bf=$ba ;; esac; done
      backup_restore "$bf" ;;
    node) cli_node "$@" ;;
    chain) cli_chain "$@" ;;
    optimize) if [[ ${1:-} == --revert ]]; then optimize_revert; else optimize_apply; fi ;;
    update) nxr_update "$@" ;;
    uninstall)
      local ua
      for ua in "$@"; do
        case $ua in -y|--yes) ASSUME_YES=1 ;; --purge) OPT_PURGE=1 ;; *) err "未知参数: $ua"; return 2 ;; esac
      done
      nxr_uninstall ;;
    install) self_install --force && ok "已安装: $NXR_BIN" ;;
    *) err "未知命令: $cmd"; usage; return 2 ;;
  esac
}

# 被 source 时只加载函数
if [[ -n ${BASH_SOURCE[0]:-} && ${BASH_SOURCE[0]} != "$0" ]]; then return 0 2>/dev/null; fi
main "$@"
