#!/usr/bin/env bash
# ============================================================
#  综合服务器工具箱 (Debian 12)
#  模块: 1) 开启引导   2) 定期 Ping 监控   3) 定期测 IP 质量   4) 定期 YABS 测试
# ============================================================
set -o pipefail

# ---------- locale 兜底 (避免多字节乱码) ----------
if ! locale 2>/dev/null | grep -qi 'UTF-8'; then
  export LANG=C.UTF-8 LC_ALL=C.UTF-8 2>/dev/null || true
fi

# ---------- 全局路径 ----------
TOOL_DIR="/etc/sshtool"
PING_DIR="${TOOL_DIR}/ping"
PING_DATA="${PING_DIR}/data"
PING_CONF="${PING_DIR}/targets.conf"     # 格式: ip|备注
PING_SETTING="${PING_DIR}/settings.conf" # INTERVAL= / RETAIN_DAYS=
IPQ_DIR="${TOOL_DIR}/ipquality"
IPQ_DATA="${IPQ_DIR}/data"
IPQ_KEEP="${IPQ_DIR}/keep"      # 长期保留目录, 自动清理不删
IPQ_SETTING="${IPQ_DIR}/settings.conf"
YABS_DIR="${TOOL_DIR}/yabs"
YABS_DATA="${YABS_DIR}/data"
YABS_KEEP="${YABS_DIR}/keep"
YABS_SETTING="${YABS_DIR}/settings.conf"
BENCH_DIR="${TOOL_DIR}/bench"
BENCH_DATA="${BENCH_DIR}/data"
BENCH_KEEP="${BENCH_DIR}/keep"
BENCH_SETTING="${BENCH_DIR}/settings.conf"
NQ_DIR="${TOOL_DIR}/nodequality"
NQ_DATA="${NQ_DIR}/data"
NQ_KEEP="${NQ_DIR}/keep"
NQ_SETTING="${NQ_DIR}/settings.conf"

# ---------- 颜色 ----------
C_RESET="\033[0m"; C_RED="\033[31m"; C_GRN="\033[32m"; C_YEL="\033[33m"
C_BLU="\033[34m"; C_CYN="\033[36m"; C_BOLD="\033[1m"; C_GRY="\033[90m"

# ---------- 小工具 ----------
err(){ echo -e "${C_RED}[错误]${C_RESET} $*" >&2; }
ok(){ echo -e "${C_GRN}[成功]${C_RESET} $*"; }
pause(){ read -rp "按回车继续..." _; }
safe_name(){ echo "$1" | sed 's#[/:*?"<>| ]#_#g'; }

timer_base_pm30(){ # 输出“中心时间 -30分钟”的 HH:MM，用于配合 RandomizedDelaySec=1h 实现 ±30分钟
  local h="$1" m="$2"
  python3 - "$h" "$m" <<'PYT'
import sys
from datetime import datetime, timedelta
h=int(sys.argv[1]); m=int(sys.argv[2])
dt=datetime(2000,1,1,h,m)-timedelta(minutes=30)
print(dt.strftime('%H:%M'))
PYT
}
timer_random_line(){
  echo "RandomizedDelaySec=1h"
}

read_int_range(){
  # 用法: read_int_range "提示" "当前值" 最小 最大
  # 只接受数字；空回车保留当前值。
  local prompt="$1" current="$2" min="$3" max="$4" v
  while true; do
    read -rp "${prompt} [当前 ${current}，直接回车保留]: " v
    v="${v:-$current}"
    if [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -ge "$min" ] && [ "$v" -le "$max" ]; then
      printf '%02d\n' "$v"
      return 0
    fi
    err "只能输入 ${min}-${max} 之间的数字，不要输入英文、冒号或其它符号。"
  done
}

read_positive_int(){
  # 用法: read_positive_int "提示" "当前值"
  # 只接受正整数；空回车保留当前值。
  local prompt="$1" current="$2" v
  while true; do
    read -rp "${prompt} [当前 ${current}，直接回车保留]: " v
    v="${v:-$current}"
    if [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -gt 0 ]; then
      printf '%s\n' "$v"
      return 0
    fi
    err "只能输入大于 0 的数字，不要输入英文或其它符号。"
  done
}

init_dirs(){
  mkdir -p "$PING_DATA" "$IPQ_DATA" "$IPQ_KEEP" "$YABS_DATA" "$YABS_KEEP" "$BENCH_DATA" "$BENCH_KEEP" "$NQ_DATA" "$NQ_KEEP"
  [ -f "$PING_SETTING" ] || printf 'INTERVAL=60\nRETAIN_DAYS=7\n' > "$PING_SETTING"
  [ -f "$IPQ_SETTING" ]  || printf 'HOUR=03\nMINUTE=00\nRETAIN_DAYS=30\n' > "$IPQ_SETTING"
  [ -f "$YABS_SETTING" ] || printf 'HOUR=04\nMINUTE=00\nRETAIN_DAYS=30\n' > "$YABS_SETTING"
  [ -f "$BENCH_SETTING" ] || printf 'HOUR=05\nMINUTE=00\nRETAIN_DAYS=30\n' > "$BENCH_SETTING"
  [ -f "$NQ_SETTING" ] || printf 'INTERVAL_DAYS=7\nHOUR=06\nMINUTE=00\nEVENING_HOUR=22\nEVENING_MINUTE=00\nSTART_DATE=%s\nRETAIN_DAYS=30\n' "$(date '+%Y-%m-%d')" > "$NQ_SETTING"
  touch "$PING_CONF"
}

# ---------- 日志清洗: 查看 IP 质量报告时裁掉报告正文前的杂质 ----------
# v2: 不再只依赖 clear 的 ESC[2J/ESC[3J；优先用“IP质量体检报告”作为正文锚点。
# 这样单独查看和全部查看都会自动跳过依赖安装输出、apt 报错、TERM 报错、赞助商块等前置垃圾。
strip_clear(){
  local f="$1"
  perl -0777 - "$f" <<'PL'
use strict;
use warnings;

my $file = $ARGV[0];
open my $fh, '<', $file or die "无法读取 $file: $!\n";
local $/;
my $text = <$fh>;
close $fh;
$text = '' unless defined $text;

# 兼容旧逻辑：如果日志里确实存在整屏清屏，先取最后一次清屏后的内容。
my $last_clear = -1;
while ($text =~ /\e\[(?:2|3)J/g) {
  $last_clear = pos($text);
}
$text = substr($text, $last_clear) if $last_clear >= 0;

# spinner/进度动画常用 \r 原地刷新；按行保留最后一帧。
my @lines;
for my $line (split /\n/, $text, -1) {
  my @parts = split /\r/, $line, -1;
  push @lines, (@parts ? $parts[-1] : '');
}
$text = join "\n", @lines;

# 去掉会影响查看的终端控制码，但保留 SGR 颜色码（ESC[...m）。
# 这样仍然能裁掉清屏/光标移动/OSC 标题等垃圾控制符，同时保留 IPQuality 报告原本的彩色输出。
$text =~ s/\e\][^\a]*(?:\a|\e\\)//g;       # OSC/title
$text =~ s/\e\[([0-?]*[ -\/]*)([@-~])/$2 eq 'm' ? "\e[$1$2" : ''/ge;  # keep SGR colors only
$text =~ s/\e[()][AB0]//g;                  # charset selection
$text =~ s/\e[@-Z\\-_]//g;                  # other one-char ESC sequences

# 关键优化：定位真正报告正文。
my $anchor = index($text, 'IP质量体检报告');
if ($anchor >= 0) {
  # 尽量从报告标题上方那行 ####### 分隔线开始，而不是从标题字样中间开始。
  my $prefix = substr($text, 0, $anchor);
  my $hash_pos = rindex($prefix, '########################################################################');
  if ($hash_pos >= 0) {
    $text = substr($text, $hash_pos);
  } else {
    my $line_start = rindex($prefix, "\n");
    $text = substr($text, $line_start >= 0 ? $line_start + 1 : $anchor);
  }
} elsif ($text =~ /(?m)^#{20,}\s*$/) {
  # 兜底：如果报告格式以后改了，尽量裁掉常见前置垃圾，从第一个“大段分隔线”开始。
  $text = substr($text, $-[0]);
}

# 去掉常见孤立噪声行，避免锚点未命中时仍然很脏。
my @out;
for my $line (split /\n/, $text) {
  $line =~ s/[ \t]+$//;
  next if $line =~ /^\s*TERM environment variable not set\.\s*$/;
  push @out, $line;
}
$text = join "\n", @out;
$text =~ s/^\n+//;
$text =~ s/\n+$//;
print $text, "\n" if length $text;
PL
}

# ============================================================
#  状态检测
# ============================================================
ping_status_text(){
  if systemctl is-active --quiet sshtool-ping.service 2>/dev/null; then
    echo -e "${C_GRN}运行中${C_RESET}"
  else
    echo -e "${C_GRY}未运行${C_RESET}"
  fi
}
ipquality_enabled(){ systemctl is-enabled --quiet sshtool-ipquality.timer 2>/dev/null; }
ipq_status_text(){
  if ipquality_enabled; then echo -e "${C_GRN}运行中${C_RESET}"
  else echo -e "${C_GRY}未运行${C_RESET}"; fi
}
ipq_hour(){
  local h
  h=$(grep -E '^HOUR=' "$IPQ_SETTING" 2>/dev/null | cut -d= -f2)
  h=${h:-03}
  if [[ "$h" =~ ^[0-9]{1,2}$ ]] && [ "$h" -ge 0 ] && [ "$h" -le 23 ]; then
    printf '%02d' "$h"
  else
    printf '03'
  fi
}
ipq_minute(){
  local m
  m=$(grep -E '^MINUTE=' "$IPQ_SETTING" 2>/dev/null | cut -d= -f2)
  m=${m:-00}
  if [[ "$m" =~ ^[0-9]{1,2}$ ]] && [ "$m" -ge 0 ] && [ "$m" -le 59 ]; then
    printf '%02d' "$m"
  else
    printf '00'
  fi
}
yabs_enabled(){ systemctl is-enabled --quiet sshtool-yabs.timer 2>/dev/null; }
yabs_status_text(){
  if yabs_enabled; then echo -e "${C_GRN}运行中${C_RESET}"
  else echo -e "${C_GRY}未运行${C_RESET}"; fi
}
bench_enabled(){ systemctl is-enabled --quiet sshtool-bench.timer 2>/dev/null; }
bench_status_text(){
  if bench_enabled; then echo -e "${C_GRN}运行中${C_RESET}"
  else echo -e "${C_GRY}未运行${C_RESET}"; fi
}
nq_enabled(){ systemctl is-enabled --quiet sshtool-nodequality.timer 2>/dev/null; }
nq_status_text(){
  if nq_enabled; then echo -e "${C_GRN}运行中${C_RESET}"
  else echo -e "${C_GRY}未运行${C_RESET}"; fi
}
yabs_hour(){
  local h
  h=$(grep -E '^HOUR=' "$YABS_SETTING" 2>/dev/null | cut -d= -f2)
  h=${h:-04}
  if [[ "$h" =~ ^[0-9]{1,2}$ ]] && [ "$h" -ge 0 ] && [ "$h" -le 23 ]; then
    printf '%02d' "$h"
  else
    printf '04'
  fi
}
yabs_minute(){
  local m
  m=$(grep -E '^MINUTE=' "$YABS_SETTING" 2>/dev/null | cut -d= -f2)
  m=${m:-00}
  if [[ "$m" =~ ^[0-9]{1,2}$ ]] && [ "$m" -ge 0 ] && [ "$m" -le 59 ]; then
    printf '%02d' "$m"
  else
    printf '00'
  fi
}


yabs_prepare_swap_if_needed(){
  # YABS 在小内存机器上容易因为内存不足中断；开启定时/执行前自动补足 swap。
  # 规则：物理内存不足 1024MB 时，按差额创建/调整专用 swap 文件。
  # 例如 MemTotal≈500MB，则创建约 524MB 的 /swapfile.sshtool-yabs。
  local target_mb=1024
  local mem_mb deficit_mb swapfile cur_mb avail_mb
  swapfile="/swapfile.sshtool-yabs"

  mem_mb=$(awk '/MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null)
  if ! [[ "${mem_mb:-}" =~ ^[0-9]+$ ]]; then
    err "无法读取当前内存大小，跳过自动 swap 检查"
    return 0
  fi

  if [ "$mem_mb" -ge "$target_mb" ]; then
    echo "内存 ${mem_mb}MB 已达到 ${target_mb}MB，无需为 YABS 额外添加 swap。"
    return 0
  fi

  deficit_mb=$((target_mb - mem_mb))
  [ "$deficit_mb" -lt 1 ] && deficit_mb=1

  cur_mb=0
  if [ -f "$swapfile" ]; then
    cur_mb=$(du -m "$swapfile" 2>/dev/null | awk '{print $1}')
    cur_mb=${cur_mb:-0}
  fi

  if [ "$cur_mb" -ge "$deficit_mb" ] && swapon --show=NAME --noheadings 2>/dev/null | grep -qx "$swapfile"; then
    echo "内存 ${mem_mb}MB 未达到 ${target_mb}MB；专用 swap 已存在并启用：${swapfile} (${cur_mb}MB)。"
    return 0
  fi

  avail_mb=$(df -Pm / | awk 'NR==2 {print $4}')
  avail_mb=${avail_mb:-0}
  if [ "$avail_mb" -le $((deficit_mb + 64)) ]; then
    err "磁盘剩余空间不足，无法创建 ${deficit_mb}MB swap 文件（当前可用约 ${avail_mb}MB）"
    return 1
  fi

  echo "内存 ${mem_mb}MB 未达到 ${target_mb}MB，自动为 YABS 添加 ${deficit_mb}MB swap：${swapfile}"

  if swapon --show=NAME --noheadings 2>/dev/null | grep -qx "$swapfile"; then
    swapoff "$swapfile" || return 1
  fi
  rm -f "$swapfile"

  if command -v fallocate >/dev/null 2>&1; then
    fallocate -l "${deficit_mb}M" "$swapfile" 2>/dev/null || dd if=/dev/zero of="$swapfile" bs=1M count="$deficit_mb" status=none
  else
    dd if=/dev/zero of="$swapfile" bs=1M count="$deficit_mb" status=none
  fi
  chmod 600 "$swapfile"
  mkswap "$swapfile" >/dev/null
  swapon "$swapfile"

  # 持久化，避免重启后丢失；先清掉旧的同路径记录，再追加。
  if [ -f /etc/fstab ]; then
    awk -v sf="$swapfile" '$1 != sf {print}' /etc/fstab > /etc/fstab.sshtool.tmp && mv /etc/fstab.sshtool.tmp /etc/fstab
  fi
  echo "$swapfile none swap sw 0 0" >> /etc/fstab

  ok "YABS 专用 swap 已启用：${deficit_mb}MB"
}
bench_hour(){
  local h
  h=$(grep -E '^HOUR=' "$BENCH_SETTING" 2>/dev/null | cut -d= -f2)
  h=${h:-05}
  if [[ "$h" =~ ^[0-9]{1,2}$ ]] && [ "$h" -ge 0 ] && [ "$h" -le 23 ]; then
    printf '%02d' "$h"
  else
    printf '05'
  fi
}
bench_minute(){
  local m
  m=$(grep -E '^MINUTE=' "$BENCH_SETTING" 2>/dev/null | cut -d= -f2)
  m=${m:-00}
  if [[ "$m" =~ ^[0-9]{1,2}$ ]] && [ "$m" -ge 0 ] && [ "$m" -le 59 ]; then
    printf '%02d' "$m"
  else
    printf '00'
  fi
}

nq_interval_days(){
  local n
  n=$(grep -E '^INTERVAL_DAYS=' "$NQ_SETTING" 2>/dev/null | cut -d= -f2)
  n=${n:-7}
  if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -gt 0 ]; then echo "$n"; else echo 7; fi
}
nq_start_date(){
  local d
  d=$(grep -E '^START_DATE=' "$NQ_SETTING" 2>/dev/null | cut -d= -f2)
  if date -d "$d" '+%Y-%m-%d' >/dev/null 2>&1; then date -d "$d" '+%Y-%m-%d'; else date '+%Y-%m-%d'; fi
}
nq_hour(){
  local h
  h=$(grep -E '^HOUR=' "$NQ_SETTING" 2>/dev/null | cut -d= -f2)
  h=${h:-06}
  if [[ "$h" =~ ^[0-9]{1,2}$ ]] && [ "$h" -ge 0 ] && [ "$h" -le 23 ]; then
    printf '%02d' "$h"
  else
    printf '06'
  fi
}
nq_minute(){
  local m
  m=$(grep -E '^MINUTE=' "$NQ_SETTING" 2>/dev/null | cut -d= -f2)
  m=${m:-00}
  if [[ "$m" =~ ^[0-9]{1,2}$ ]] && [ "$m" -ge 0 ] && [ "$m" -le 59 ]; then
    printf '%02d' "$m"
  else
    printf '00'
  fi
}
nq_evening_hour(){
  local h
  h=$(grep -E '^EVENING_HOUR=' "$NQ_SETTING" 2>/dev/null | cut -d= -f2)
  h=${h:-22}
  if [[ "$h" =~ ^[0-9]{1,2}$ ]] && [ "$h" -ge 0 ] && [ "$h" -le 23 ]; then
    printf '%02d' "$h"
  else
    printf '22'
  fi
}
nq_evening_minute(){
  local m
  m=$(grep -E '^EVENING_MINUTE=' "$NQ_SETTING" 2>/dev/null | cut -d= -f2)
  m=${m:-00}
  if [[ "$m" =~ ^[0-9]{1,2}$ ]] && [ "$m" -ge 0 ] && [ "$m" -le 59 ]; then
    printf '%02d' "$m"
  else
    printf '00'
  fi
}
nq_due_today(){
  local start interval today_s start_s days
  start="$(nq_start_date)"; interval="$(nq_interval_days)"
  today_s=$(date -d "$(date '+%Y-%m-%d')" '+%s') || return 1
  start_s=$(date -d "$start" '+%s') || return 1
  days=$(( (today_s - start_s) / 86400 ))
  [ "$days" -ge 0 ] && [ $((days % interval)) -eq 0 ]
}
run_nq_scheduled(){
  init_dirs
  if nq_due_today; then
    run_nq_once
  else
    echo "今天不是 NodeQuality 循环检测日（起点: $(nq_start_date)，间隔: $(nq_interval_days) 天），跳过。"
  fi
}
nq_write_settings(){
  local interval="$1" hour="$2" minute="$3" ehour="$4" eminute="$5" start_date="$6" retain="$7"
  printf 'INTERVAL_DAYS=%s\nHOUR=%s\nMINUTE=%s\nEVENING_HOUR=%s\nEVENING_MINUTE=%s\nSTART_DATE=%s\nRETAIN_DAYS=%s\n' \
    "$interval" "$hour" "$minute" "$ehour" "$eminute" "$start_date" "$retain" > "$NQ_SETTING"
}

# ============================================================
#  采集
# ============================================================
self_path(){ readlink -f "$0" 2>/dev/null || echo "$0"; }

run_ping_daemon(){
  init_dirs
  while true; do
    local interval; interval=$(grep -E '^INTERVAL=' "$PING_SETTING" 2>/dev/null | cut -d= -f2)
    interval=${interval:-60}
    local retain; retain=$(grep -E '^RETAIN_DAYS=' "$PING_SETTING" 2>/dev/null | cut -d= -f2)
    retain=${retain:-7}
    # 遍历所有目标 ping 一次
    if [ -s "$PING_CONF" ]; then
      while IFS='|' read -r ip note; do
        [ -z "$ip" ] && continue
        local out rtt status now csv
        out=$(ping -c1 -W2 "$ip" 2>/dev/null)
        if echo "$out" | grep -q 'time='; then
          rtt=$(echo "$out" | grep -oE 'time=[0-9.]+' | head -1 | cut -d= -f2)
          status="OK"
        else
          rtt=""; status="TIMEOUT"
        fi
        now=$(date '+%Y-%m-%d %H:%M:%S')
        csv="${PING_DATA}/$(safe_name "$ip").csv"
        echo "${now},${ip},${rtt},${status}" >> "$csv"
      done < "$PING_CONF"
    fi
    # 过期清理(按行时间)
    find "$PING_DATA" -type f -name '*.csv' -mtime +"$retain" -delete 2>/dev/null
    sleep "$interval"
  done
}


run_ipquality_once(){
  init_dirs
  local fpath="${IPQ_DATA}/$(date '+%Y-%m-%d_%H时%M分%S秒').log"
  { echo "===== IP质量检测 $(date '+%Y-%m-%d %H:%M:%S') ====="
    bash <(curl -sL IP.Check.Place) -y 2>&1; } > "$fpath"
  local retain; retain=$(grep -E '^RETAIN_DAYS=' "$IPQ_SETTING" 2>/dev/null | cut -d= -f2); retain=${retain:-30}
  find "$IPQ_DATA" -type f -name '*.log' -mtime +"$retain" -delete 2>/dev/null
  echo "已保存: $fpath"
}

run_yabs_once(){
  init_dirs
  local fpath="${YABS_DATA}/$(date '+%Y-%m-%d_%H时%M分%S秒').log"
  { echo "===== YABS 测试 $(date '+%Y-%m-%d %H:%M:%S') ====="
    echo "命令: curl -sL yabs.sh | bash -s -- -i -5"
    echo
    yabs_prepare_swap_if_needed || { echo "Swap 准备失败，取消 YABS 测试。"; return 1; }
    echo
    curl -sL yabs.sh | bash -s -- -i -5 2>&1
    echo
    echo "===== YABS 测试结束 $(date '+%Y-%m-%d %H:%M:%S') ====="
  } > "$fpath"
  local retain; retain=$(grep -E '^RETAIN_DAYS=' "$YABS_SETTING" 2>/dev/null | cut -d= -f2); retain=${retain:-30}
  find "$YABS_DATA" -type f -name '*.log' -mtime +"$retain" -delete 2>/dev/null
  echo "已保存: $fpath"
}

run_bench_once(){
  init_dirs
  local fpath="${BENCH_DATA}/$(date '+%Y-%m-%d_%H时%M分%S秒').log"
  { echo "===== Bench.sh 测试 $(date '+%Y-%m-%d %H:%M:%S') ====="
    echo "命令: wget -qO- bench.sh | bash"
    echo
    wget -qO- bench.sh | bash 2>&1
    echo
    echo "===== Bench.sh 测试结束 $(date '+%Y-%m-%d %H:%M:%S') ====="
  } > "$fpath"
  local retain; retain=$(grep -E '^RETAIN_DAYS=' "$BENCH_SETTING" 2>/dev/null | cut -d= -f2); retain=${retain:-30}
  find "$BENCH_DATA" -type f -name '*.log' -mtime +"$retain" -delete 2>/dev/null
  echo "已保存: $fpath"
}

run_nq_once(){
  init_dirs
  local fpath raw links retain
  fpath="${NQ_DATA}/$(date '+%Y-%m-%d_%H时%M分%S秒').log"
  raw=$(mktemp)
  printf 'v\ny\ny\ny\n' | bash <(curl -sL https://run.NodeQuality.com) > "$raw" 2>&1
  links=$(grep -aoE 'https://nodequality\.com/r/[A-Za-z0-9]+' "$raw" | awk '!seen[$0]++')
  {
    echo "===== NodeQuality 检测链接 $(date '+%Y-%m-%d %H:%M:%S') ====="
    echo "命令: printf 'v\\ny\\ny\\ny\\n' | bash <(curl -sL https://run.NodeQuality.com)"
    echo
    if [ -n "$links" ]; then
      echo "$links"
    else
      echo "未提取到 nodequality.com 结果链接。"
    fi
    echo
    echo "===== NodeQuality 检测结束 $(date '+%Y-%m-%d %H:%M:%S') ====="
  } > "$fpath"
  rm -f "$raw"
  retain=$(grep -E '^RETAIN_DAYS=' "$NQ_SETTING" 2>/dev/null | cut -d= -f2); retain=${retain:-30}
  find "$NQ_DATA" -type f -name '*.log' -mtime +"$retain" -delete 2>/dev/null
  echo "已保存: $fpath"
}

# ============================================================
#  systemd 管理
# ============================================================
install_ping_service(){
  init_dirs
  local sp; sp="$(self_path)"
  cat > /etc/systemd/system/sshtool-ping.service <<EOF
[Unit]
Description=sshtool periodic ping monitor
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/env bash ${sp} __ping_daemon
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now sshtool-ping.service
  ok "定期 Ping 监控已开启"
}
disable_ping_service(){
  systemctl disable --now sshtool-ping.service 2>/dev/null
  rm -f /etc/systemd/system/sshtool-ping.service
  systemctl daemon-reload
  ok "定期 Ping 监控已关闭"
}

install_ipquality_timer(){
  init_dirs
  local sp hour minute base base_h base_m
  sp="$(self_path)"
  hour="$(ipq_hour)"
  minute="$(ipq_minute)"
  base="$(timer_base_pm30 "$hour" "$minute")"; base_h="${base%:*}"; base_m="${base#*:}"
  cat > /etc/systemd/system/sshtool-ipquality.service <<EOF
[Unit]
Description=sshtool IP quality check (oneshot)
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/bin/env bash ${sp} __ipq_once
EOF
  cat > /etc/systemd/system/sshtool-ipquality.timer <<EOF
[Unit]
Description=sshtool IP quality daily timer

[Timer]
OnCalendar=*-*-* ${base_h}:${base_m}:00
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now sshtool-ipquality.timer
  ok "定期测 IP 质量已开启 (每天 ${hour}:${minute} ±30分钟)"
}
disable_ipquality_timer(){
  systemctl disable --now sshtool-ipquality.timer 2>/dev/null
  rm -f /etc/systemd/system/sshtool-ipquality.timer /etc/systemd/system/sshtool-ipquality.service
  systemctl daemon-reload
  ok "定期测 IP 质量已关闭"
}

install_yabs_timer(){
  init_dirs
  local sp hour minute base base_h base_m
  sp="$(self_path)"
  hour="$(yabs_hour)"
  minute="$(yabs_minute)"
  base="$(timer_base_pm30 "$hour" "$minute")"; base_h="${base%:*}"; base_m="${base#*:}"
  yabs_prepare_swap_if_needed || return 1
  cat > /etc/systemd/system/sshtool-yabs.service <<EOF
[Unit]
Description=sshtool YABS benchmark (oneshot)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/env bash ${sp} __yabs_once
EOF
  cat > /etc/systemd/system/sshtool-yabs.timer <<EOF
[Unit]
Description=sshtool YABS daily timer

[Timer]
OnCalendar=*-*-* ${base_h}:${base_m}:00
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now sshtool-yabs.timer
  ok "定期 YABS 测试已开启 (每天 ${hour}:${minute} ±30分钟)"
}
disable_yabs_timer(){
  systemctl disable --now sshtool-yabs.timer 2>/dev/null
  rm -f /etc/systemd/system/sshtool-yabs.timer /etc/systemd/system/sshtool-yabs.service
  systemctl daemon-reload
  ok "定期 YABS 测试已关闭"
}

install_bench_timer(){
  init_dirs
  local sp hour minute base base_h base_m
  sp="$(self_path)"
  hour="$(bench_hour)"
  minute="$(bench_minute)"
  base="$(timer_base_pm30 "$hour" "$minute")"; base_h="${base%:*}"; base_m="${base#*:}"
  cat > /etc/systemd/system/sshtool-bench.service <<EOF
[Unit]
Description=sshtool Bench.sh benchmark (oneshot)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/env bash ${sp} __bench_once
EOF
  cat > /etc/systemd/system/sshtool-bench.timer <<EOF
[Unit]
Description=sshtool Bench.sh daily timer

[Timer]
OnCalendar=*-*-* ${base_h}:${base_m}:00
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now sshtool-bench.timer
  ok "定期 Bench.sh 测试已开启 (每天 ${hour}:${minute} ±30分钟)"
}
disable_bench_timer(){
  systemctl disable --now sshtool-bench.timer 2>/dev/null
  rm -f /etc/systemd/system/sshtool-bench.timer /etc/systemd/system/sshtool-bench.service
  systemctl daemon-reload
  ok "定期 Bench.sh 测试已关闭"
}

install_nq_timer(){
  init_dirs
  local sp interval hour minute ehour eminute retain start_date base1 base2 b1h b1m b2h b2m
  sp="$(self_path)"
  interval="$(nq_interval_days)"
  hour="$(nq_hour)"; minute="$(nq_minute)"
  ehour="$(nq_evening_hour)"; eminute="$(nq_evening_minute)"
  retain=$(grep -E '^RETAIN_DAYS=' "$NQ_SETTING" 2>/dev/null | cut -d= -f2); retain=${retain:-30}
  start_date="$(date '+%Y-%m-%d')"
  nq_write_settings "$interval" "$hour" "$minute" "$ehour" "$eminute" "$start_date" "$retain"
  base1="$(timer_base_pm30 "$hour" "$minute")"; b1h="${base1%:*}"; b1m="${base1#*:}"
  base2="$(timer_base_pm30 "$ehour" "$eminute")"; b2h="${base2%:*}"; b2m="${base2#*:}"
  cat > /etc/systemd/system/sshtool-nodequality.service <<EOF
[Unit]
Description=sshtool NodeQuality scheduled check (oneshot)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/env bash ${sp} __nq_scheduled
EOF
  cat > /etc/systemd/system/sshtool-nodequality.timer <<EOF
[Unit]
Description=sshtool NodeQuality interval timer

[Timer]
OnCalendar=*-*-* ${b1h}:${b1m}:00
OnCalendar=*-*-* ${b2h}:${b2m}:00
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now sshtool-nodequality.timer
  ok "定期 NodeQuality 检测已开启 (从今天开始，每 ${interval} 天：${hour}:${minute} ±30分钟 + 同日 ${ehour}:${eminute} ±30分钟)"
}
disable_nq_timer(){
  systemctl disable --now sshtool-nodequality.timer 2>/dev/null
  rm -f /etc/systemd/system/sshtool-nodequality.timer /etc/systemd/system/sshtool-nodequality.service
  systemctl daemon-reload
  ok "定期 NodeQuality 检测已关闭"
}

# ============================================================
#  Ping 结果展示
# ============================================================
# 把指定时间范围的数据过滤到临时文件
filter_to_tmp(){ # filter_to_tmp csv文件 范围(1h/1d/all) 输出tmp
  local csv="$1" range="$2" out="$3"
  : > "$out"
  [ -f "$csv" ] || return
  if [ "$range" = "all" ]; then cp "$csv" "$out"; return; fi
  local cutoff
  if [ "$range" = "1h" ]; then cutoff=$(date -d '1 hour ago' '+%Y-%m-%d %H:%M:%S')
  else cutoff=$(date -d '1 day ago' '+%Y-%m-%d %H:%M:%S'); fi
  awk -F, -v c="$cutoff" '$1 >= c' "$csv" > "$out"
}

# A: 趋势条 + 统计
view_A(){ # view_A tmp文件 目标名
  local tmp="$1" name="$2"
  local total ok_c loss_c
  total=$(wc -l < "$tmp"); total=${total:-0}
  if [ "$total" -eq 0 ]; then echo "  (无数据)"; return; fi
  ok_c=$(awk -F, '$4=="OK"' "$tmp" | wc -l)
  loss_c=$((total-ok_c))
  local avg min max
  avg=$(awk -F, '$4=="OK"&&$3!=""{s+=$3;n++} END{if(n>0)printf "%.1f",s/n; else print "-"}' "$tmp")
  min=$(awk -F, '$4=="OK"&&$3!=""{if(m==""||$3<m)m=$3} END{print (m==""?"-":m)}' "$tmp")
  max=$(awk -F, '$4=="OK"&&$3!=""{if($3>m)m=$3} END{print (m==""?"-":m)}' "$tmp")
  local loss_pct; loss_pct=$(awk -v l="$loss_c" -v t="$total" 'BEGIN{printf "%.0f", (t>0?l*100/t:0)}')
  echo -e "  ${C_BOLD}${name}${C_RESET}"
  echo -e "  样本:${total}  丢包:${loss_pct}%  延迟(ms) 均:${avg} 最小:${min} 最大:${max}"
  # 趋势条: 每个样本一个彩色块, 取最近 60 个
  local bars=""
  local chars; chars=$(awk -F, '{print $3","$4}' "$tmp" | tail -60)
  local line c rtt st col
  while IFS=, read -r rtt st; do
    if [ "$st" != "OK" ]; then col="$C_RED"; c="x"
    elif [ -z "$rtt" ]; then col="$C_RED"; c="x"
    else
      awk_res=$(awk -v r="$rtt" 'BEGIN{ if(r<80)print"g"; else if(r<=200)print"y"; else print"r" }')
      case "$awk_res" in g) col="$C_GRN";; y) col="$C_YEL";; r) col="$C_RED";; esac
      c="|"
    fi
    bars="${bars}${col}${c}"
  done <<< "$chars"
  echo -e "  最近趋势: ${bars}${C_RESET}"
  echo -e "  ${C_GRN}|绿<80${C_RESET} ${C_YEL}|黄80-200${C_RESET} ${C_RED}|红>200/x超时${C_RESET}"
}

# B: 带编号分段(按小时分段), 填充 SEG_* 数组供钻取
declare -a SEG_LABEL SEG_START SEG_END
view_B(){ # view_B tmp文件
  SEG_LABEL=(); SEG_START=(); SEG_END=()
  local tmp="$1"
  [ -s "$tmp" ] || { echo "  (无数据)"; return; }
  # 按"年-月-日 时"分组
  local segs; segs=$(awk -F, '{print substr($1,1,13)}' "$tmp" | sort -u)
  local i=0 seg cnt okc loss avg dot col
  echo -e "  ${C_BOLD}分段概览 (按小时):${C_RESET}"
  while IFS= read -r seg; do
    [ -z "$seg" ] && continue
    cnt=$(awk -F, -v s="$seg" 'substr($1,1,13)==s' "$tmp" | wc -l)
    okc=$(awk -F, -v s="$seg" 'substr($1,1,13)==s && $4=="OK"' "$tmp" | wc -l)
    loss=$((cnt-okc))
    avg=$(awk -F, -v s="$seg" 'substr($1,1,13)==s && $4=="OK" && $3!=""{x+=$3;n++} END{if(n>0)printf "%.0f",x/n; else print "-"}' "$tmp")
    # 圆点颜色: 有丢包->红, 平均>200->红, >80->黄, 否则绿
    if [ "$loss" -gt 0 ]; then col="$C_RED"
    elif [ "$avg" = "-" ]; then col="$C_RED"
    else col=$(awk -v a="$avg" 'BEGIN{if(a<80)print"\033[32m";else if(a<=200)print"\033[33m";else print"\033[31m"}')
    fi
    i=$((i+1))
    SEG_LABEL[$i]="$seg"; SEG_START[$i]="$seg"
    printf "  %b●%b %d) %s  样本:%d 丢包:%d 均:%sms\n" "$col" "$C_RESET" "$((i+1))" "$seg" "$cnt" "$loss" "$avg"
  done <<< "$segs"
  SEG_COUNT=$i
}

# 钻取某段明细(竖向, 带彩色圆点)
drill_segment(){ # drill_segment tmp文件 段标签
  local tmp="$1" seg="$2"
  clear
  echo -e "${C_BOLD}== 明细: ${seg} ==${C_RESET}"
  echo "  时间                  目标            延迟    状态"
  echo "  ----------------------------------------------------"
  awk -F, -v s="$seg" 'substr($1,1,13)==s' "$tmp" | while IFS=, read -r t ip rtt st; do
    local col dot
    if [ "$st" != "OK" ]; then col="$C_RED"
    elif [ -z "$rtt" ]; then col="$C_RED"
    else col=$(awk -v r="$rtt" 'BEGIN{if(r<80)print"\033[32m";else if(r<=200)print"\033[33m";else print"\033[31m"}')
    fi
    printf "  %b●%b %-19s %-15s %-7s %s\n" "$col" "$C_RESET" "$t" "$ip" "${rtt:--}" "$st"
  done
  pause
}

ping_view_one(){ # ping_view_one csv文件 目标名 范围
  local csv="$1" name="$2" range="$3"
  local tmp; tmp=$(mktemp)
  filter_to_tmp "$csv" "$range" "$tmp"
  while true; do
    clear
    echo -e "${C_BOLD}== ${name} (${range}) ==${C_RESET}\n"
    view_A "$tmp" "$name"
    echo
    view_B "$tmp"
    echo
    echo "  输入分段编号查看明细, 0) 返回"
    read -rp "选择: " sel
    case "$sel" in
      0|"") rm -f "$tmp"; return;;
      *)
        if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 2 ] && [ "$sel" -le "$((SEG_COUNT+1))" ]; then
          drill_segment "$tmp" "${SEG_LABEL[$((sel-1))]}"
        else rm -f "$tmp"; return; fi;;
    esac
  done
}

# ============================================================
#  Ping 菜单
# ============================================================
menu_ping_view(){
  while true; do
    clear
    echo -e "${C_BOLD}== 查看 Ping 结果 ==${C_RESET}"
    # 选时间范围
    echo "  请选择时间范围:"
    echo "  1) 最近 1 小时"
    echo "  2) 最近 1 天"
    echo "  3) 全部"
    echo "  0) 返回"
    read -rp "选择: " r
    local range
    case "$r" in
      1) range="1h";; 2) range="1d";; 3) range="all";;
      0|"") return;; *) return;;
    esac
    # 列目标
    while true; do
      clear
      echo -e "${C_BOLD}== 选择目标 (${range}) ==${C_RESET}"
      local -a tgts=() notes=()
      local idx=0 ip note
      if [ -s "$PING_CONF" ]; then
        while IFS='|' read -r ip note; do
          [ -z "$ip" ] && continue
          idx=$((idx+1)); tgts+=("$ip"); notes+=("$note")
        done < "$PING_CONF"
      fi
      if [ "$idx" -eq 0 ]; then echo "暂无 Ping 目标。"; pause; return; fi
      echo -e "  ${C_CYN}1) 全部目标·概况一览${C_RESET}"
      local k; for k in $(seq 0 $((idx-1))); do
        printf "  %d) %s %s\n" "$((k+2))" "${tgts[$k]}" "${notes[$k]:+(${notes[$k]})}"
      done
      echo "  0) 返回"
      read -rp "选择编号: " sel
      case "$sel" in
        0|"") break;;
        1)
          clear
          echo -e "${C_BOLD}== 全部目标·概况 (${range}) ==${C_RESET}\n"
          local j; for j in $(seq 0 $((idx-1))); do
            local csv tmp
            csv="${PING_DATA}/$(safe_name "${tgts[$j]}").csv"
            tmp=$(mktemp); filter_to_tmp "$csv" "$range" "$tmp"
            view_A "$tmp" "${tgts[$j]} ${notes[$j]:+(${notes[$j]})}"
            echo; rm -f "$tmp"
          done
          pause;;
        *)
          if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 2 ] && [ "$sel" -le "$((idx+1))" ]; then
            local csv; csv="${PING_DATA}/$(safe_name "${tgts[$((sel-2))]}").csv"
            ping_view_one "$csv" "${tgts[$((sel-2))]}" "$range"
          else break; fi;;
      esac
    done
  done
}

menu_ping_add(){
  clear
  echo -e "${C_BOLD}== 添加 Ping 目标 ==${C_RESET}"
  read -rp "输入 IP/域名 (空回车取消): " ip
  [ -z "$ip" ] && return
  read -rp "备注 (可空): " note
  echo "${ip}|${note}" >> "$PING_CONF"
  ok "已添加: ${ip}"
  pause
}

menu_ping_settings(){
  while true; do
    clear
    init_dirs
    local interval retain
    interval=$(grep -E '^INTERVAL=' "$PING_SETTING" | cut -d= -f2)
    retain=$(grep -E '^RETAIN_DAYS=' "$PING_SETTING" | cut -d= -f2)
    echo -e "${C_BOLD}== Ping 设置 ==${C_RESET}"
    echo "  当前: 每 ${interval} 秒 ping 一次, 保留 ${retain} 天"
    echo "  1) 修改 ping 间隔(秒)"
    echo "  2) 修改保留天数"
    echo "  3) 管理目标备注/删除"
    echo "  0) 返回"
    read -rp "选择: " s
    case "$s" in
      1) read -rp "新间隔(秒): " v
         if [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -gt 0 ]; then
           sed -i "s/^INTERVAL=.*/INTERVAL=${v}/" "$PING_SETTING"; ok "已更新"
         else err "无效数值"; fi; sleep 1;;
      2) read -rp "新保留天数: " v
         if [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -gt 0 ]; then
           sed -i "s/^RETAIN_DAYS=.*/RETAIN_DAYS=${v}/" "$PING_SETTING"; ok "已更新"
         else err "无效数值"; fi; sleep 1;;
      3) menu_ping_target_manage;;
      0|"") return;;
      *) return;;
    esac
  done
}

menu_ping_target_manage(){
  while true; do
    clear
    echo -e "${C_BOLD}== 管理目标 ==${C_RESET}"
    local -a tgts=() notes=()
    local idx=0 ip note
    if [ -s "$PING_CONF" ]; then
      while IFS='|' read -r ip note; do
        [ -z "$ip" ] && continue
        idx=$((idx+1)); tgts+=("$ip"); notes+=("$note")
      done < "$PING_CONF"
    fi
    if [ "$idx" -eq 0 ]; then echo "暂无目标。"; pause; return; fi
    local k; for k in $(seq 0 $((idx-1))); do
      printf "  %d) %s %s\n" "$((k+1))" "${tgts[$k]}" "${notes[$k]:+(${notes[$k]})}"
    done
    echo "  0) 返回"
    read -rp "选编号修改, 0返回: " sel
    case "$sel" in
      0|"") return;;
      *)
        if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le "$idx" ]; then
          local cur="${tgts[$((sel-1))]}"
          echo "  1) 改备注  2) 删除  0) 取消"
          read -rp "操作: " op
          case "$op" in
            1) read -rp "新备注: " nn
               sed -i "s#^${cur}|.*#${cur}|${nn}#" "$PING_CONF"; ok "已改备注"; sleep 1;;
            2) sed -i "\#^${cur}|#d" "$PING_CONF"; ok "已删除"; sleep 1;;
            *) :;;
          esac
        else return; fi;;
    esac
  done
}

menu_ping(){
  while true; do
    clear
    echo -e "${C_BOLD}===== 定期 Ping 监控 =====${C_RESET}  状态: $(ping_status_text)"
    echo "  1) 查看结果"
    echo "  2) 添加目标"
    echo "  3) 设置 (间隔/保留/备注)"
    echo "  4) 开启监控"
    echo "  5) 关闭监控"
    echo "  0) 返回主菜单"
    read -rp "选择: " s
    case "$s" in
      1) menu_ping_view;;
      2) menu_ping_add;;
      3) menu_ping_settings;;
      4) install_ping_service; pause;;
      5) disable_ping_service; pause;;
      0|"") return;;
      *) return;;
    esac
  done
}

# ============================================================
#  IP 质量菜单
# ============================================================
# 单条报告查看 + 长期保留管理
ipq_view_one(){ # ipq_view_one 文件路径
  local fpath="$1"
  while true; do
    clear
    strip_clear "$fpath"
    echo
    echo "  ----------------------------------------------"
    # 判断当前所在目录, 显示对应动作
    if [ "$(dirname "$fpath")" = "$IPQ_KEEP" ]; then
      echo -e "  当前状态: ${C_YEL}[永久保留]${C_RESET}"
      echo "  1) 取消长期保留 (移回普通, 受保留天数管理)"
    else
      echo -e "  当前状态: ${C_GRY}普通 (到期自动清理)${C_RESET}"
      echo "  1) 设为长期保留 (永不自动删除)"
    fi
    echo "  0) 返回"
    read -rp "选择: " act
    case "$act" in
      1)
        local base; base="$(basename "$fpath")"
        if [ "$(dirname "$fpath")" = "$IPQ_KEEP" ]; then
          mv -f "$fpath" "${IPQ_DATA}/${base}" && { ok "已取消长期保留"; fpath="${IPQ_DATA}/${base}"; }
        else
          mv -f "$fpath" "${IPQ_KEEP}/${base}" && { ok "已设为长期保留"; fpath="${IPQ_KEEP}/${base}"; }
        fi
        sleep 1;;
      0|"") return;;
      *) return;;
    esac
  done
}

menu_ipq_view(){
  while true; do
    clear
    echo -e "${C_BOLD}== IP 质量检测结果 ==${C_RESET}"
    local -a files=() iskeep=()
    local idx=0 line p
    # 同时列出 data/ 与 keep/ 的日志, 按修改时间倒序合并
    # 输出格式: <时间戳>\t<完整路径> 便于统一排序
    while IFS=$'\t' read -r _ p; do
      [ -z "$p" ] && continue
      idx=$((idx+1)); files+=("$p")
      if [ "$(dirname "$p")" = "$IPQ_KEEP" ]; then iskeep+=("1"); else iskeep+=("0"); fi
    done < <( { ls -1t "${IPQ_DATA}"/*.log "${IPQ_KEEP}"/*.log 2>/dev/null | while IFS= read -r p; do
                 [ -e "$p" ] && printf '%s\t%s\n' "$(stat -c %Y "$p")" "$p"
               done; } | sort -t$'\t' -k1,1nr )
    if [ "$idx" -eq 0 ]; then echo "暂无检测结果。"; pause; return; fi
    echo -e "  ${C_CYN}1) 全部记录·按顺序展示${C_RESET}"
    local k tag
    for k in $(seq 0 $((idx-1))); do
      if [ "${iskeep[$k]}" = "1" ]; then tag=" ${C_YEL}[永久]${C_RESET}"; else tag=""; fi
      printf "  %d) %s%b\n" "$((k+2))" "$(basename "${files[$k]}" .log)" "$tag"
    done
    echo "  0) 返回"
    read -rp "选择编号: " sel
    case "$sel" in
      0|"") return;;
      1)
        clear
        local j t2
        # 全部查看：最新的显示在最上面，最早的显示在最底下。
        # files[] 在生成时已经按 mtime 倒序排列，这里保持 0 -> idx-1 顺序输出。
        for j in $(seq 0 $((idx-1))); do
          if [ "${iskeep[$j]}" = "1" ]; then t2=" [永久]"; else t2=""; fi
          echo -e "\n========== $(basename "${files[$j]}" .log)${t2} ==========\n"
          strip_clear "${files[$j]}"
        done
        pause;;
      *)
        if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 2 ] && [ "$sel" -le "$((idx+1))" ]; then
          ipq_view_one "${files[$((sel-2))]}"
        else return; fi;;
    esac
  done
}

menu_ipq_settings(){
  init_dirs
  while true; do
    clear
    local hour minute retain
    hour="$(ipq_hour)"
    minute="$(ipq_minute)"
    retain=$(grep -E '^RETAIN_DAYS=' "$IPQ_SETTING" 2>/dev/null | cut -d= -f2); retain=${retain:-30}
    echo -e "${C_BOLD}== IP 质量设置 ==${C_RESET}"
    echo "  当前定时: 每天 ${hour}:${minute} ±30分钟"
    echo "  结果保留: ${retain} 天"
    echo
    echo "  设置说明：这里只需要输入数字。"
    echo "  示例：想设置为凌晨 3 点整，就选 1 后：小时输入 3，分钟输入 0。"
    echo "        因为带 ±30分钟，实际会在 02:30-03:30 之间随机执行。"
    echo
    echo "  1) 修改定时时间（默认 03:00 ±30分钟）"
    echo "  2) 修改保留天数"
    echo "  0) 返回"
    read -rp "选择: " s
    case "$s" in
      1)
        echo
        echo "请输入中心时间，只填数字，不要输入冒号。"
        echo "例：03:00 -> 小时填 3，分钟填 0"
        local nh nm
        nh=$(read_int_range "小时 0-23" "$hour" 0 23) || { sleep 1; continue; }
        nm=$(read_int_range "分钟 0-59" "$minute" 0 59) || { sleep 1; continue; }
        printf 'HOUR=%02d
MINUTE=%02d
RETAIN_DAYS=%s
' "$nh" "$nm" "$retain" > "$IPQ_SETTING"
        ok "已设置为每天 $(printf '%02d' "$nh"):$(printf '%02d' "$nm") ±30分钟"
        if ipquality_enabled; then install_ipquality_timer >/dev/null; ok "已同步更新 systemd timer"; fi
        sleep 1;;
      2)
        echo
        echo "请输入结果保留天数，只填数字。"
        echo "例：保留 30 天就输入 30；保留 90 天就输入 90。"
        local nr
        nr=$(read_positive_int "保留天数" "$retain") || { sleep 1; continue; }
        printf 'HOUR=%s
MINUTE=%s
RETAIN_DAYS=%s
' "$hour" "$minute" "$nr" > "$IPQ_SETTING"
        ok "已设置保留 ${nr} 天"
        sleep 1;;
      0|"") return;;
      *) return;;
    esac
  done
}

menu_ipq(){
  while true; do
    clear
    echo -e "${C_BOLD}===== 定期测 IP 质量 =====${C_RESET}  状态: $(ipq_status_text)"
    echo "  1) 查看结果"
    echo "  2) 开启定时（默认每天 $(ipq_hour):$(ipq_minute) ±30分钟）"
    echo "  3) 立即测试一次"
    echo "  4) 设置"
    echo "  5) 关闭定时"
    echo "  0) 返回主菜单"
    read -rp "选择: " s
    case "$s" in
      1) menu_ipq_view;;
      2) install_ipquality_timer; pause;;
      3) echo "检测中, 请稍候..."; run_ipquality_once; ok "完成"; pause;;
      4) menu_ipq_settings;;
      5) disable_ipquality_timer; pause;;
      0|"") return;;
      *) return;;
    esac
  done
}

# ============================================================
#  YABS 菜单
# ============================================================
yabs_view_one(){
  local fpath="$1"
  while true; do
    clear
    cat "$fpath"
    echo
    echo "  ----------------------------------------------"
    if [ "$(dirname "$fpath")" = "$YABS_KEEP" ]; then
      echo -e "  当前状态: ${C_YEL}[永久保留]${C_RESET}"
      echo "  1) 取消长期保留 (移回普通, 受保留天数管理)"
    else
      echo -e "  当前状态: ${C_GRY}普通 (到期自动清理)${C_RESET}"
      echo "  1) 设为长期保留 (永不自动删除)"
    fi
    echo "  0) 返回"
    read -rp "选择: " act
    case "$act" in
      1)
        local base; base="$(basename "$fpath")"
        if [ "$(dirname "$fpath")" = "$YABS_KEEP" ]; then
          mv -f "$fpath" "${YABS_DATA}/${base}" && { ok "已取消长期保留"; fpath="${YABS_DATA}/${base}"; }
        else
          mv -f "$fpath" "${YABS_KEEP}/${base}" && { ok "已设为长期保留"; fpath="${YABS_KEEP}/${base}"; }
        fi
        sleep 1;;
      0|"") return;;
      *) return;;
    esac
  done
}

menu_yabs_view(){
  while true; do
    clear
    echo -e "${C_BOLD}== YABS 测试结果 ==${C_RESET}"
    local -a files=() iskeep=()
    local idx=0 p
    while IFS=$'	' read -r _ p; do
      [ -z "$p" ] && continue
      idx=$((idx+1)); files+=("$p")
      if [ "$(dirname "$p")" = "$YABS_KEEP" ]; then iskeep+=("1"); else iskeep+=("0"); fi
    done < <( { ls -1t "${YABS_DATA}"/*.log "${YABS_KEEP}"/*.log 2>/dev/null | while IFS= read -r p; do
                 [ -e "$p" ] && printf '%s	%s
' "$(stat -c %Y "$p")" "$p"
               done; } | sort -t$'	' -k1,1nr )
    if [ "$idx" -eq 0 ]; then echo "暂无 YABS 测试结果。"; pause; return; fi
    echo -e "  ${C_CYN}1) 全部记录·按顺序展示${C_RESET}"
    local k tag
    for k in $(seq 0 $((idx-1))); do
      if [ "${iskeep[$k]}" = "1" ]; then tag=" ${C_YEL}[永久]${C_RESET}"; else tag=""; fi
      printf "  %d) %s%b
" "$((k+2))" "$(basename "${files[$k]}" .log)" "$tag"
    done
    echo "  0) 返回"
    read -rp "选择编号: " sel
    case "$sel" in
      0|"") return;;
      1)
        clear
        local j t2
        # 全部查看：最新的显示在最上面，最早的显示在最底下。
        # files[] 在生成时已经按 mtime 倒序排列，这里保持 0 -> idx-1 顺序输出。
        for j in $(seq 0 $((idx-1))); do
          if [ "${iskeep[$j]}" = "1" ]; then t2=" [永久]"; else t2=""; fi
          echo -e "
========== $(basename "${files[$j]}" .log)${t2} ==========
"
          cat "${files[$j]}"
        done
        pause;;
      *)
        if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 2 ] && [ "$sel" -le "$((idx+1))" ]; then
          yabs_view_one "${files[$((sel-2))]}"
        else return; fi;;
    esac
  done
}

menu_yabs_settings(){
  init_dirs
  while true; do
    clear
    local hour minute retain
    hour="$(yabs_hour)"
    minute="$(yabs_minute)"
    retain=$(grep -E '^RETAIN_DAYS=' "$YABS_SETTING" 2>/dev/null | cut -d= -f2); retain=${retain:-30}
    echo -e "${C_BOLD}== YABS 设置 ==${C_RESET}"
    echo "  当前定时: 每天 ${hour}:${minute} ±30分钟"
    echo "  结果保留: ${retain} 天"
    echo
    echo "  设置说明：这里只需要输入数字。"
    echo "  示例：想设置为凌晨 4 点整，就选 1 后：小时输入 4，分钟输入 0。"
    echo "        因为带 ±30分钟，实际会在 03:30-04:30 之间随机执行。"
    echo
    echo "  1) 修改定时时间（默认 04:00 ±30分钟）"
    echo "  2) 修改保留天数"
    echo "  0) 返回"
    read -rp "选择: " s
    case "$s" in
      1)
        echo
        echo "请输入中心时间，只填数字，不要输入冒号。"
        echo "例：04:00 -> 小时填 4，分钟填 0"
        local nh nm
        nh=$(read_int_range "小时 0-23" "$hour" 0 23) || { sleep 1; continue; }
        nm=$(read_int_range "分钟 0-59" "$minute" 0 59) || { sleep 1; continue; }
        printf 'HOUR=%02d
MINUTE=%02d
RETAIN_DAYS=%s
' "$nh" "$nm" "$retain" > "$YABS_SETTING"
        ok "已设置为每天 $(printf '%02d' "$nh"):$(printf '%02d' "$nm") ±30分钟"
        if yabs_enabled; then install_yabs_timer >/dev/null; ok "已同步更新 systemd timer"; fi
        sleep 1;;
      2)
        echo
        echo "请输入结果保留天数，只填数字。"
        echo "例：保留 30 天就输入 30；保留 90 天就输入 90。"
        local nr
        nr=$(read_positive_int "保留天数" "$retain") || { sleep 1; continue; }
        printf 'HOUR=%s
MINUTE=%s
RETAIN_DAYS=%s
' "$hour" "$minute" "$nr" > "$YABS_SETTING"
        ok "已设置保留 ${nr} 天"
        sleep 1;;
      0|"") return;;
      *) return;;
    esac
  done
}

menu_yabs(){
  while true; do
    clear
    echo -e "${C_BOLD}===== 定期 YABS 测试 =====${C_RESET}  状态: $(yabs_status_text)"
    echo "  1) 查看结果"
    echo "  2) 开启定时（默认每天 $(yabs_hour):$(yabs_minute) ±30分钟）"
    echo "  3) 立即测试一次"
    echo "  4) 设置"
    echo "  5) 关闭定时"
    echo "  0) 返回主菜单"
    read -rp "选择: " s
    case "$s" in
      1) menu_yabs_view;;
      2) install_yabs_timer; pause;;
      3) echo "YABS 测试中, 请稍候..."; run_yabs_once; ok "完成"; pause;;
      4) menu_yabs_settings;;
      5) disable_yabs_timer; pause;;
      0|"") return;;
      *) return;;
    esac
  done
}


# ============================================================
#  Bench.sh 测试菜单
# ============================================================
bench_view_one(){
  local fpath="$1"
  while true; do
    clear
    cat "$fpath"
    echo
    echo "  ----------------------------------------------"
    if [ "$(dirname "$fpath")" = "$BENCH_KEEP" ]; then
      echo -e "  当前状态: ${C_YEL}[永久保留]${C_RESET}"
      echo "  1) 取消长期保留 (移回普通, 受保留天数管理)"
    else
      echo -e "  当前状态: ${C_GRY}普通 (到期自动清理)${C_RESET}"
      echo "  1) 设为长期保留 (永不自动删除)"
    fi
    echo "  0) 返回"
    read -rp "选择: " act
    case "$act" in
      1)
        local base; base="$(basename "$fpath")"
        if [ "$(dirname "$fpath")" = "$BENCH_KEEP" ]; then
          mv -f "$fpath" "${BENCH_DATA}/${base}" && { ok "已取消长期保留"; fpath="${BENCH_DATA}/${base}"; }
        else
          mv -f "$fpath" "${BENCH_KEEP}/${base}" && { ok "已设为长期保留"; fpath="${BENCH_KEEP}/${base}"; }
        fi
        sleep 1;;
      0|"") return;;
      *) return;;
    esac
  done
}

menu_bench_view(){
  while true; do
    clear
    echo -e "${C_BOLD}== Bench.sh 测试结果 ==${C_RESET}"
    local -a files=() iskeep=()
    local idx=0 p
    while IFS=$'\t' read -r _ p; do
      [ -z "$p" ] && continue
      idx=$((idx+1)); files+=("$p")
      if [ "$(dirname "$p")" = "$BENCH_KEEP" ]; then iskeep+=("1"); else iskeep+=("0"); fi
    done < <( { ls -1t "${BENCH_DATA}"/*.log "${BENCH_KEEP}"/*.log 2>/dev/null | while IFS= read -r p; do
                 [ -e "$p" ] && printf '%s\t%s\n' "$(stat -c %Y "$p")" "$p"
               done; } | sort -t$'\t' -k1,1nr )
    if [ "$idx" -eq 0 ]; then echo "暂无 Bench.sh 测试结果。"; pause; return; fi
    echo -e "  ${C_CYN}1) 全部记录·按顺序展示${C_RESET}"
    local k tag
    for k in $(seq 0 $((idx-1))); do
      if [ "${iskeep[$k]}" = "1" ]; then tag=" ${C_YEL}[永久]${C_RESET}"; else tag=""; fi
      printf "  %d) %s%b\n" "$((k+2))" "$(basename "${files[$k]}" .log)" "$tag"
    done
    echo "  0) 返回"
    read -rp "选择编号: " sel
    case "$sel" in
      0|"") return;;
      1)
        clear
        local j t2
        # 全部查看：最新的显示在最上面，最早的显示在最底下。
        # files[] 在生成时已经按 mtime 倒序排列，这里保持 0 -> idx-1 顺序输出。
        for j in $(seq 0 $((idx-1))); do
          if [ "${iskeep[$j]}" = "1" ]; then t2=" [永久]"; else t2=""; fi
          echo -e "\n========== $(basename "${files[$j]}" .log)${t2} =========="
          echo
          cat "${files[$j]}"
        done
        pause;;
      *)
        if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 2 ] && [ "$sel" -le "$((idx+1))" ]; then
          bench_view_one "${files[$((sel-2))]}"
        else return; fi;;
    esac
  done
}

menu_bench_settings(){
  init_dirs
  while true; do
    clear
    local hour minute retain
    hour="$(bench_hour)"
    minute="$(bench_minute)"
    retain=$(grep -E '^RETAIN_DAYS=' "$BENCH_SETTING" 2>/dev/null | cut -d= -f2); retain=${retain:-30}
    echo -e "${C_BOLD}== Bench.sh 设置 ==${C_RESET}"
    echo "  当前定时: 每天 ${hour}:${minute} ±30分钟"
    echo "  结果保留: ${retain} 天"
    echo
    echo "  设置说明：这里只需要输入数字。"
    echo "  示例：想设置为凌晨 5 点整，就选 1 后：小时输入 5，分钟输入 0。"
    echo "        因为带 ±30分钟，实际会在 04:30-05:30 之间随机执行。"
    echo
    echo "  1) 修改定时时间（默认 05:00 ±30分钟）"
    echo "  2) 修改保留天数"
    echo "  0) 返回"
    read -rp "选择: " s
    case "$s" in
      1)
        echo
        echo "请输入中心时间，只填数字，不要输入冒号。"
        echo "例：05:00 -> 小时填 5，分钟填 0"
        local nh nm
        nh=$(read_int_range "小时 0-23" "$hour" 0 23) || { sleep 1; continue; }
        nm=$(read_int_range "分钟 0-59" "$minute" 0 59) || { sleep 1; continue; }
        printf 'HOUR=%02d
MINUTE=%02d
RETAIN_DAYS=%s
' "$nh" "$nm" "$retain" > "$BENCH_SETTING"
        ok "已设置为每天 $(printf '%02d' "$nh"):$(printf '%02d' "$nm") ±30分钟"
        if bench_enabled; then install_bench_timer >/dev/null; ok "已同步更新 systemd timer"; fi
        sleep 1;;
      2)
        echo
        echo "请输入结果保留天数，只填数字。"
        echo "例：保留 30 天就输入 30；保留 90 天就输入 90。"
        local nr
        nr=$(read_positive_int "保留天数" "$retain") || { sleep 1; continue; }
        printf 'HOUR=%s
MINUTE=%s
RETAIN_DAYS=%s
' "$hour" "$minute" "$nr" > "$BENCH_SETTING"
        ok "已设置保留 ${nr} 天"
        sleep 1;;
      0|"") return;;
      *) return;;
    esac
  done
}

menu_bench(){
  while true; do
    clear
    echo -e "${C_BOLD}===== 定期 Bench.sh 测试 =====${C_RESET}  状态: $(bench_status_text)"
    echo "  1) 查看结果"
    echo "  2) 开启定时（默认每天 $(bench_hour):$(bench_minute) ±30分钟）"
    echo "  3) 立即测试一次"
    echo "  4) 设置"
    echo "  5) 关闭定时"
    echo "  0) 返回主菜单"
    read -rp "选择: " s
    case "$s" in
      1) menu_bench_view;;
      2) install_bench_timer; pause;;
      3) echo "Bench.sh 测试中，请稍候..."; run_bench_once; ok "完成"; pause;;
      4) menu_bench_settings;;
      5) disable_bench_timer; pause;;
      0|"") return;;
      *) return;;
    esac
  done
}


# ============================================================
#  NodeQuality 菜单
# ============================================================
nq_view_one(){
  local fpath="$1"
  while true; do
    clear
    cat "$fpath"
    echo
    echo "  ----------------------------------------------"
    if [ "$(dirname "$fpath")" = "$NQ_KEEP" ]; then
      echo -e "  当前状态: ${C_YEL}[永久保留]${C_RESET}"
      echo "  1) 取消长期保留 (移回普通, 受保留天数管理)"
    else
      echo -e "  当前状态: ${C_GRY}普通 (到期自动清理)${C_RESET}"
      echo "  1) 设为长期保留 (永不自动删除)"
    fi
    echo "  0) 返回"
    read -rp "选择: " act
    case "$act" in
      1)
        local base; base="$(basename "$fpath")"
        if [ "$(dirname "$fpath")" = "$NQ_KEEP" ]; then
          mv -f "$fpath" "${NQ_DATA}/${base}" && { ok "已取消长期保留"; fpath="${NQ_DATA}/${base}"; }
        else
          mv -f "$fpath" "${NQ_KEEP}/${base}" && { ok "已设为长期保留"; fpath="${NQ_KEEP}/${base}"; }
        fi
        sleep 1;;
      0|"") return;;
      *) return;;
    esac
  done
}

menu_nq_view(){
  while true; do
    clear
    echo -e "${C_BOLD}== NodeQuality 检测结果链接 ==${C_RESET}"
    local -a files=() iskeep=()
    local idx=0 p
    while IFS=$'\t' read -r _ p; do
      [ -z "$p" ] && continue
      idx=$((idx+1)); files+=("$p")
      if [ "$(dirname "$p")" = "$NQ_KEEP" ]; then iskeep+=("1"); else iskeep+=("0"); fi
    done < <( { ls -1t "${NQ_DATA}"/*.log "${NQ_KEEP}"/*.log 2>/dev/null | while IFS= read -r p; do
                 [ -e "$p" ] && printf '%s\t%s\n' "$(stat -c %Y "$p")" "$p"
               done; } | sort -t$'\t' -k1,1nr )
    if [ "$idx" -eq 0 ]; then echo "暂无 NodeQuality 检测结果链接。"; pause; return; fi
    echo -e "  ${C_CYN}1) 全部记录·按顺序展示${C_RESET}"
    local k tag
    for k in $(seq 0 $((idx-1))); do
      if [ "${iskeep[$k]}" = "1" ]; then tag=" ${C_YEL}[永久]${C_RESET}"; else tag=""; fi
      printf "  %d) %s%b\n" "$((k+2))" "$(basename "${files[$k]}" .log)" "$tag"
    done
    echo "  0) 返回"
    read -rp "选择编号: " sel
    case "$sel" in
      0|"") return;;
      1)
        clear
        local j t2
        for j in $(seq 0 $((idx-1))); do
          if [ "${iskeep[$j]}" = "1" ]; then t2=" [永久]"; else t2=""; fi
          echo -e "\n========== $(basename "${files[$j]}" .log)${t2} =========="
          echo
          cat "${files[$j]}"
        done
        pause;;
      *)
        if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 2 ] && [ "$sel" -le "$((idx+1))" ]; then
          nq_view_one "${files[$((sel-2))]}"
        else return; fi;;
    esac
  done
}

menu_nq_settings(){
  init_dirs
  while true; do
    clear
    local interval hour minute ehour eminute start_date retain
    interval="$(nq_interval_days)"
    hour="$(nq_hour)"; minute="$(nq_minute)"
    ehour="$(nq_evening_hour)"; eminute="$(nq_evening_minute)"
    start_date="$(nq_start_date)"
    retain=$(grep -E '^RETAIN_DAYS=' "$NQ_SETTING" 2>/dev/null | cut -d= -f2); retain=${retain:-30}
    echo -e "${C_BOLD}== NodeQuality 设置 ==${C_RESET}"
    echo "  当前循环: 从 ${start_date} 开始，每 ${interval} 天检测一次"
    echo "  当前定时: 当天 ${hour}:${minute} ±30分钟 + 晚高峰 ${ehour}:${eminute} ±30分钟"
    echo "  结果保留: ${retain} 天"
    echo
    echo "  设置说明：这里只需要输入数字。"
    echo "  示例1：想每 7 天测一次，就选 1 后输入 7。"
    echo "  示例2：想早上 6 点测，就选 2 后：小时输入 6，分钟输入 0。"
    echo "  示例3：想晚高峰 22 点测，就选 3 后：小时输入 22，分钟输入 0。"
    echo "  说明：±30分钟表示 06:00 会在 05:30-06:30 间随机执行。"
    echo
    echo "  1) 修改检测间隔天数（默认 7）"
    echo "  2) 修改白天检测时间（默认 06:00 ±30分钟）"
    echo "  3) 修改晚高峰检测时间（默认 22:00 ±30分钟）"
    echo "  4) 修改保留天数"
    echo "  0) 返回"
    read -rp "选择: " s
    case "$s" in
      1)
        echo
        echo "请输入检测间隔天数，只填数字。"
        echo "例：每 7 天测一次就输入 7；每 3 天测一次就输入 3。"
        local ni
        ni=$(read_positive_int "间隔天数" "$interval") || { sleep 1; continue; }
        nq_write_settings "$ni" "$hour" "$minute" "$ehour" "$eminute" "$start_date" "$retain"
        ok "已设置为每 ${ni} 天检测一次"
        if nq_enabled; then install_nq_timer >/dev/null; ok "已同步更新 systemd timer，并从今天重新开始循环"; fi
        sleep 1;;
      2)
        echo
        echo "请输入白天检测的中心时间，只填数字，不要输入冒号。"
        echo "例：06:00 -> 小时填 6，分钟填 0；实际 05:30-06:30 随机执行。"
        local nh nm
        nh=$(read_int_range "小时 0-23" "$hour" 0 23) || { sleep 1; continue; }
        nm=$(read_int_range "分钟 0-59" "$minute" 0 59) || { sleep 1; continue; }
        nq_write_settings "$interval" "$(printf '%02d' "$nh")" "$(printf '%02d' "$nm")" "$ehour" "$eminute" "$start_date" "$retain"
        ok "已设置白天检测为 $(printf '%02d' "$nh"):$(printf '%02d' "$nm") ±30分钟"
        if nq_enabled; then install_nq_timer >/dev/null; ok "已同步更新 systemd timer，并从今天重新开始循环"; fi
        sleep 1;;
      3)
        echo
        echo "请输入晚高峰检测的中心时间，只填数字，不要输入冒号。"
        echo "例：22:00 -> 小时填 22，分钟填 0；实际 21:30-22:30 随机执行。"
        local nh nm
        nh=$(read_int_range "小时 0-23" "$ehour" 0 23) || { sleep 1; continue; }
        nm=$(read_int_range "分钟 0-59" "$eminute" 0 59) || { sleep 1; continue; }
        nq_write_settings "$interval" "$hour" "$minute" "$(printf '%02d' "$nh")" "$(printf '%02d' "$nm")" "$start_date" "$retain"
        ok "已设置晚高峰检测为 $(printf '%02d' "$nh"):$(printf '%02d' "$nm") ±30分钟"
        if nq_enabled; then install_nq_timer >/dev/null; ok "已同步更新 systemd timer，并从今天重新开始循环"; fi
        sleep 1;;
      4)
        echo
        echo "请输入结果保留天数，只填数字。"
        echo "例：保留 30 天就输入 30；保留 90 天就输入 90。"
        local nr
        nr=$(read_positive_int "保留天数" "$retain") || { sleep 1; continue; }
        nq_write_settings "$interval" "$hour" "$minute" "$ehour" "$eminute" "$start_date" "$nr"
        ok "已设置保留 ${nr} 天"
        sleep 1;;
      0|"") return;;
      *) return;;
    esac
  done
}

menu_nq(){
  while true; do
    clear
    echo -e "${C_BOLD}===== 定期 NodeQuality 检测 =====${C_RESET}  状态: $(nq_status_text)"
    echo "  1) 查看结果"
    echo "  2) 开启定时（默认每 $(nq_interval_days) 天：$(nq_hour):$(nq_minute) ±30分钟 + 同日 $(nq_evening_hour):$(nq_evening_minute) ±30分钟）"
    echo "  3) 立即测试一次"
    echo "  4) 设置"
    echo "  5) 关闭定时"
    echo "  0) 返回主菜单"
    read -rp "选择: " s
    case "$s" in
      1) menu_nq_view;;
      2) install_nq_timer; pause;;
      3) echo "NodeQuality 检测中，请稍候..."; run_nq_once; ok "完成，已只保存 nodequality.com 结果链接"; pause;;
      4) menu_nq_settings;;
      5) disable_nq_timer; pause;;
      0|"") return;;
      *) return;;
    esac
  done
}


menu_start_guide(){
  clear
  echo -e "${C_BOLD}===== 开启引导 =====${C_RESET}"
  echo
  echo "使用方式："
  echo "  - 直接回车：按默认推荐开启"
  echo "  - 输入 1：逐个功能单独引导， 每项输入数字 1=开启，2=不开启"
  echo
  echo "默认推荐开启："
  echo "  - 定期测 IP 质量（每天 03:00 ±30分钟）"
  echo "  - 定期 YABS 测试（每天 04:00 ±30分钟；开启前会自动检查内存/swap）"
  echo
  echo "默认不自动开启，需要按需手动或在单独引导里开启："
  echo "  - 定期 Ping 监控"
  echo "  - 定期 Bench.sh 测试（每天 05:00 ±30分钟）"
  echo "  - 定期 NodeQuality 检测（每 7 天 06:00 ±30分钟 + 同日 22:00 ±30分钟）"
  echo
  read -rp "直接回车按默认开启；输入 1 进入逐个引导；输入 2 取消: " ans

  if [ -z "$ans" ]; then
    echo
    echo "正在开启：定期测 IP 质量..."
    if install_ipquality_timer; then
      ok "定期测 IP 质量已开启"
    else
      err "定期测 IP 质量开启失败"
    fi

    echo
    echo "正在开启：定期 YABS 测试..."
    if install_yabs_timer; then
      ok "定期 YABS 测试已开启"
    else
      err "定期 YABS 测试开启失败"
    fi

    echo
    echo -e "${C_BOLD}引导完成。${C_RESET}"
    echo "默认已处理："
    echo "  - 定期测 IP 质量"
    echo "  - 定期 YABS 测试"
    echo
    echo "提醒：另外三个不会自动开启，需要你在主菜单里手动打开："
    echo "  2) 定期 Ping 监控"
    echo "  5) 定期 Bench.sh 测试（默认每天 $(bench_hour):$(bench_minute) ±30分钟）"
    echo "  6) 定期 NodeQuality 检测（默认每 $(nq_interval_days) 天 $(nq_hour):$(nq_minute) ±30分钟 + 同日 $(nq_evening_hour):$(nq_evening_minute) ±30分钟）"
    pause
    return
  fi

  if [ "$ans" = "2" ]; then
    echo "已取消开启引导。"
    pause
    return
  fi

  if [ "$ans" != "1" ]; then
    echo "输入无效，已返回主菜单。"
    pause
    return
  fi

  clear
  echo -e "${C_BOLD}===== 逐个功能开启引导 =====${C_RESET}"
  echo
  echo "说明：下面每个功能都只输入数字。"
  echo "  1 = 开启"
  echo "  2 = 不开启"
  echo "  直接回车 = 不开启这一项"
  echo

  local enabled_list=""
  local skipped_list=""
  local choice=""

  guide_enable_one(){
    local title="$1"
    local hint="$2"
    local cmd="$3"
    echo
    echo "是否开启：${title}"
    echo "说明：${hint}"
    read -rp "请输入 1 开启，2 不开启: " choice
    case "$choice" in
      1)
        echo "正在开启：${title}..."
        if "$cmd"; then
          ok "${title} 已开启"
          enabled_list="${enabled_list}\n  - ${title}"
        else
          err "${title} 开启失败"
          skipped_list="${skipped_list}\n  - ${title}（开启失败）"
        fi
        ;;
      2|"")
        echo "已跳过：${title}"
        skipped_list="${skipped_list}\n  - ${title}"
        ;;
      *)
        echo "输入无效，按不开启处理：${title}"
        skipped_list="${skipped_list}\n  - ${title}"
        ;;
    esac
  }

  guide_enable_one "定期 Ping 监控" "用于持续记录目标延迟/丢包；可先到 Ping 菜单添加目标。" install_ping_service
  guide_enable_one "定期测 IP 质量" "默认每天 03:00 ±30分钟执行。" install_ipquality_timer
  guide_enable_one "定期 YABS 测试" "默认每天 04:00 ±30分钟执行；开启前会自动检查内存/swap。" install_yabs_timer
  guide_enable_one "定期 Bench.sh 测试" "默认每天 05:00 ±30分钟执行。" install_bench_timer
  guide_enable_one "定期 NodeQuality 检测" "默认每 7 天循环；开启当天开始算，同一天 06:00 ±30分钟和 22:00 ±30分钟各测一次。" install_nq_timer

  echo
  echo -e "${C_BOLD}逐个引导完成。${C_RESET}"
  if [ -n "$enabled_list" ]; then
    echo "已开启："
    printf "%b\n" "$enabled_list"
  else
    echo "已开启：无"
  fi
  echo
  if [ -n "$skipped_list" ]; then
    echo "未开启/跳过："
    printf "%b\n" "$skipped_list"
  fi
  pause
}

# ============================================================
#  主菜单
# ============================================================
main_menu(){
  init_dirs
  while true; do
    clear
    echo -e "${C_BOLD}╔══════════════════════════════╗${C_RESET}"
    echo -e "${C_BOLD}║          小鸡别太闲          ║${C_RESET}"
    echo -e "${C_BOLD}╚══════════════════════════════╝${C_RESET}"
    echo -e "  定期 Ping 监控 : $(ping_status_text)"
    echo -e "  定期测 IP 质量 : $(ipq_status_text)"
    echo -e "  定期 YABS 测试 : $(yabs_status_text)"
    echo -e "  定期 Bench.sh 测试 : $(bench_status_text)"
    echo -e "  定期 NodeQuality 检测 : $(nq_status_text)"
    echo "  ------------------------------"
    echo "  1) 开启引导"
    echo "  2) 定期 Ping 监控"
    echo "  3) 定期测 IP 质量（默认每天 $(ipq_hour):$(ipq_minute) ±30分钟）"
    echo "  4) 定期 YABS 测试（默认每天 $(yabs_hour):$(yabs_minute) ±30分钟）"
    echo "  5) 定期 Bench.sh 测试（默认每天 $(bench_hour):$(bench_minute) ±30分钟）"
    echo "  6) 定期 NodeQuality 检测（默认每 $(nq_interval_days) 天 $(nq_hour):$(nq_minute) ±30分钟 + 同日 $(nq_evening_hour):$(nq_evening_minute) ±30分钟）"
    echo "  0) 退出"
    read -rp "选择: " s
    case "$s" in
      1) menu_start_guide;;
      2) menu_ping;;
      3) menu_ipq;;
      4) menu_yabs;;
      5) menu_bench;;
      6) menu_nq;;
      0|"") clear; exit 0;;
      *) :;;
    esac
  done
}

# ============================================================
#  入口
# ============================================================
case "${1:-}" in
  __ping_daemon) run_ping_daemon;;
  __ipq_once)    run_ipquality_once;;
  __yabs_once)   run_yabs_once;;
  __bench_once)  run_bench_once;;
  __nq_once)     run_nq_once;;
  __nq_scheduled) run_nq_scheduled;;
  __strip_clear) shift; strip_clear "$1";;
  *)
    if [ "$(id -u)" -ne 0 ]; then
      err "请用 root 运行 (sudo bash $0)"; exit 1
    fi
    main_menu;;
esac
