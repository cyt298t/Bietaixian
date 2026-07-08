#!/usr/bin/env bash
# ============================================================
#  Server Utility Toolbox (Debian 12)
#  Modules: 1) Setup Wizard   2) Scheduled Ping Monitor   3) Scheduled IP Quality Test   4) Scheduled YABS Test
# ============================================================
set -o pipefail

# ---------- Locale fallback (avoid multibyte garbling) ----------
if ! locale 2>/dev/null | grep -qi 'UTF-8'; then
  export LANG=C.UTF-8 LC_ALL=C.UTF-8 2>/dev/null || true
fi

# ---------- Global paths ----------
TOOL_DIR="/etc/sshtool"
PING_DIR="${TOOL_DIR}/ping"
PING_DATA="${PING_DIR}/data"
PING_CONF="${PING_DIR}/targets.conf"     # format: ip|note
PING_SETTING="${PING_DIR}/settings.conf" # INTERVAL= / RETAIN_DAYS=
IPQ_DIR="${TOOL_DIR}/ipquality"
IPQ_DATA="${IPQ_DIR}/data"
IPQ_KEEP="${IPQ_DIR}/keep"      # long-term keep directory, excluded from auto cleanup
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

# ---------- Colors ----------
C_RESET="\033[0m"; C_RED="\033[31m"; C_GRN="\033[32m"; C_YEL="\033[33m"
C_BLU="\033[34m"; C_CYN="\033[36m"; C_BOLD="\033[1m"; C_GRY="\033[90m"

# ---------- Small helpers ----------
err(){ echo -e "${C_RED}[ERROR]${C_RESET} $*" >&2; }
ok(){ echo -e "${C_GRN}[OK]${C_RESET} $*"; }
pause(){ read -rp "Press Enter to continue..." _; }
safe_name(){ echo "$1" | sed 's#[/:*?"<>| ]#_#g'; }

timer_base_pm30(){ # print the configured HH:MM itself; used with RandomizedDelaySec=30min for +0~30 minutes randomized delay; pure bash, no python3 required
  local h="$1" m="$2" total
  h=$((10#$h)); m=$((10#$m))
  total=$((h * 60 + m))
  while [ "$total" -lt 0 ]; do total=$((total + 1440)); done
  total=$((total % 1440))
  printf '%02d:%02d
' $((total / 60)) $((total % 60))
}
timer_random_line(){
  echo "RandomizedDelaySec=30min"
}

read_int_range(){
  # Usage: read_int_range "prompt" "current value" min max
  # Only numbers are accepted; press Enter to keep the current value.
  local prompt="$1" current="$2" min="$3" max="$4" v
  while true; do
    read -rp "${prompt} [current ${current}, press Enter to keep]: " v
    v="${v:-$current}"
    if [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -ge "$min" ] && [ "$v" -le "$max" ]; then
      printf '%02d\n' "$v"
      return 0
    fi
    err "Only enter a number between ${min}-${max}; do not enter letters, colons, or other symbols."
  done
}

read_positive_int(){
  # Usage: read_positive_int "prompt" "current value"
  # Only positive integers are accepted; press Enter to keep the current value.
  local prompt="$1" current="$2" v
  while true; do
    read -rp "${prompt} [current ${current}, press Enter to keep]: " v
    v="${v:-$current}"
    if [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -gt 0 ]; then
      printf '%s\n' "$v"
      return 0
    fi
    err "Only enter a number greater than 0; do not enter letters or other symbols."
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

# ---------- Log cleanup: trim junk before the IP Quality report body when viewing reports ----------
# v2: no longer relies only on clear  clear ESC[2J/ESC[3J; prefer using"IP Quality Check Report"as the body anchor。
# This skips dependency-install output, apt errors, TERM errors, sponsor blocks, and other leading junk in both single and all-record views.
strip_clear(){
  local f="$1"
  perl -0777 - "$f" <<'PL'
use strict;
use warnings;

my $file = $ARGV[0];
open my $fh, '<', $file or die "Unable to read $file: $!\n";
local $/;
my $text = <$fh>;
close $fh;
$text = '' unless defined $text;

# Backward compatibility: If the log contains full-screen clear sequences, use content after the last clear sequence first.
my $last_clear = -1;
while ($text =~ /\e\[(?:2|3)J/g) {
  $last_clear = pos($text);
}
$text = substr($text, $last_clear) if $last_clear >= 0;

# spinner/progress animations commonly use \r to refresh in place; keep the last frame per line.
my @lines;
for my $line (split /\n/, $text, -1) {
  my @parts = split /\r/, $line, -1;
  push @lines, (@parts ? $parts[-1] : '');
}
$text = join "\n", @lines;

# Remove terminal control codes that affect viewing, while keeping SGR color codes (ESC[...m)。
# This removes clear-screen/cursor-move/OSC-title junk while preserving original IPQuality colors.
$text =~ s/\e\][^\a]*(?:\a|\e\\)//g;       # OSC/title
$text =~ s/\e\[([0-?]*[ -\/]*)([@-~])/$2 eq 'm' ? "\e[$1$2" : ''/ge;  # keep SGR colors only
$text =~ s/\e[()][AB0]//g;                  # charset selection
$text =~ s/\e[@-Z\\-_]//g;                  # other one-char ESC sequences

# Key optimization: locate the real report body.
my $anchor_text = 'IP' . chr(0x8d28) . chr(0x91cf) . chr(0x4f53) . chr(0x68c0) . chr(0x62a5) . chr(0x544a);
my $anchor = index($text, $anchor_text);
if ($anchor >= 0) {
  # Try to start from the separator line above the report title ####### instead of the middle of the title text.
  my $prefix = substr($text, 0, $anchor);
  my $hash_pos = rindex($prefix, '########################################################################');
  if ($hash_pos >= 0) {
    $text = substr($text, $hash_pos);
  } else {
    my $line_start = rindex($prefix, "\n");
    $text = substr($text, $line_start >= 0 ? $line_start + 1 : $anchor);
  }
} elsif ($text =~ /(?m)^#{20,}\s*$/) {
  # Fallback: If the report format changes later, trim common leading junk and start from the first large separator.
  $text = substr($text, $-[0]);
}

# Remove common standalone noise lines so output is still cleaner if the anchor is missed.
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
#  Status checks
# ============================================================
ping_status_text(){
  if systemctl is-active --quiet sshtool-ping.service 2>/dev/null; then
    echo -e "${C_GRN}Running${C_RESET}"
  else
    echo -e "${C_GRY}Stopped${C_RESET}"
  fi
}
ipquality_enabled(){ systemctl is-enabled --quiet sshtool-ipquality.timer 2>/dev/null; }
ipq_status_text(){
  if ipquality_enabled; then echo -e "${C_GRN}Running${C_RESET}"
  else echo -e "${C_GRY}Stopped${C_RESET}"; fi
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
  if yabs_enabled; then echo -e "${C_GRN}Running${C_RESET}"
  else echo -e "${C_GRY}Stopped${C_RESET}"; fi
}
bench_enabled(){ systemctl is-enabled --quiet sshtool-bench.timer 2>/dev/null; }
bench_status_text(){
  if bench_enabled; then echo -e "${C_GRN}Running${C_RESET}"
  else echo -e "${C_GRY}Stopped${C_RESET}"; fi
}
nq_enabled(){ systemctl is-enabled --quiet sshtool-nodequality.timer 2>/dev/null; }
nq_status_text(){
  if nq_enabled; then echo -e "${C_GRN}Running${C_RESET}"
  else echo -e "${C_GRY}Stopped${C_RESET}"; fi
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
  # YABS may fail on low-memory servers; automatically top up swap before enabling/running.
  # Rule: when physical memory is below 1024MB, create/adjust a dedicated swap file for the deficit.
  # Example: if MemTotal is about 500MB, create about 524MB at /swapfile.sshtool-yabs.
  local target_mb=1024
  local mem_mb deficit_mb swapfile cur_mb avail_mb
  swapfile="/swapfile.sshtool-yabs"

  mem_mb=$(awk '/MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null)
  if ! [[ "${mem_mb:-}" =~ ^[0-9]+$ ]]; then
    err "Unable to read current memory size; skipping automatic swap check"
    return 0
  fi

  if [ "$mem_mb" -ge "$target_mb" ]; then
    echo "Memory ${mem_mb}MB already reaches ${target_mb}MB; no extra swap is needed for YABS."
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
    echo "Memory ${mem_mb}MB is below ${target_mb}MB; dedicated swap already exists and is enabled: ${swapfile} (${cur_mb}MB)."
    return 0
  fi

  avail_mb=$(df -Pm / | awk 'NR==2 {print $4}')
  avail_mb=${avail_mb:-0}
  if [ "$avail_mb" -le $((deficit_mb + 64)) ]; then
    err "Not enough free disk space to create a ${deficit_mb}MB swap file (currently available about ${avail_mb}MB)"
    return 1
  fi

  echo "Memory ${mem_mb}MB is below ${target_mb}MB; automatically adding ${deficit_mb}MB swap for YABS: ${swapfile}"

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

  # Persist it across reboot; remove old fstab entries for the same path before appending.
  if [ -f /etc/fstab ]; then
    awk -v sf="$swapfile" '$1 != sf {print}' /etc/fstab > /etc/fstab.sshtool.tmp && mv /etc/fstab.sshtool.tmp /etc/fstab
  fi
  echo "$swapfile none swap sw 0 0" >> /etc/fstab

  ok "YABS dedicated swap enabled: ${deficit_mb}MB"
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
    echo "Today is not a NodeQuality cycle test day (start: $(nq_start_date), interval: $(nq_interval_days) days), skipped."
  fi
}
nq_write_settings(){
  local interval="$1" hour="$2" minute="$3" ehour="$4" eminute="$5" start_date="$6" retain="$7"
  printf 'INTERVAL_DAYS=%s\nHOUR=%s\nMINUTE=%s\nEVENING_HOUR=%s\nEVENING_MINUTE=%s\nSTART_DATE=%s\nRETAIN_DAYS=%s\n' \
    "$interval" "$hour" "$minute" "$ehour" "$eminute" "$start_date" "$retain" > "$NQ_SETTING"
}

# ============================================================
#  Collection
# ============================================================
self_path(){ readlink -f "$0" 2>/dev/null || echo "$0"; }

run_ping_daemon(){
  init_dirs
  while true; do
    local interval; interval=$(grep -E '^INTERVAL=' "$PING_SETTING" 2>/dev/null | cut -d= -f2)
    interval=${interval:-60}
    local retain; retain=$(grep -E '^RETAIN_DAYS=' "$PING_SETTING" 2>/dev/null | cut -d= -f2)
    retain=${retain:-7}
    # Ping all targets once
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
    # Expire cleanup (by line timestamp)
    find "$PING_DATA" -type f -name '*.csv' -mtime +"$retain" -delete 2>/dev/null
    sleep "$interval"
  done
}


run_ipquality_once(){
  init_dirs
  local fpath="${IPQ_DATA}/$(date '+%Y-%m-%d_%Hh%Mm%Ss').log"
  { echo "===== IP Quality Test $(date '+%Y-%m-%d %H:%M:%S') ====="
    bash <(curl -Ls IP.Check.Place) -E -y 2>&1; } > "$fpath"
  local retain; retain=$(grep -E '^RETAIN_DAYS=' "$IPQ_SETTING" 2>/dev/null | cut -d= -f2); retain=${retain:-30}
  find "$IPQ_DATA" -type f -name '*.log' -mtime +"$retain" -delete 2>/dev/null
  echo "Saved: $fpath"
}

run_yabs_once(){
  init_dirs
  local fpath="${YABS_DATA}/$(date '+%Y-%m-%d_%Hh%Mm%Ss').log"
  { echo "===== YABS Test $(date '+%Y-%m-%d %H:%M:%S') ====="
    echo "Command: curl -sL yabs.sh | bash -s -- -i -5"
    echo
    yabs_prepare_swap_if_needed || { echo "Swap preparation failed; canceling YABS test."; return 1; }
    echo
    curl -sL yabs.sh | bash -s -- -i -5 2>&1
    echo
    echo "===== YABS Testfinished $(date '+%Y-%m-%d %H:%M:%S') ====="
  } > "$fpath"
  local retain; retain=$(grep -E '^RETAIN_DAYS=' "$YABS_SETTING" 2>/dev/null | cut -d= -f2); retain=${retain:-30}
  find "$YABS_DATA" -type f -name '*.log' -mtime +"$retain" -delete 2>/dev/null
  echo "Saved: $fpath"
}

run_bench_once(){
  init_dirs
  local fpath="${BENCH_DATA}/$(date '+%Y-%m-%d_%Hh%Mm%Ss').log"
  { echo "===== Bench.sh Test $(date '+%Y-%m-%d %H:%M:%S') ====="
    echo "Command: wget -qO- bench.sh | bash"
    echo
    wget -qO- bench.sh | bash 2>&1
    echo
    echo "===== Bench.sh Testfinished $(date '+%Y-%m-%d %H:%M:%S') ====="
  } > "$fpath"
  local retain; retain=$(grep -E '^RETAIN_DAYS=' "$BENCH_SETTING" 2>/dev/null | cut -d= -f2); retain=${retain:-30}
  find "$BENCH_DATA" -type f -name '*.log' -mtime +"$retain" -delete 2>/dev/null
  echo "Saved: $fpath"
}

run_nq_once(){
  init_dirs
  local fpath raw links retain
  fpath="${NQ_DATA}/$(date '+%Y-%m-%d_%Hh%Mm%Ss').log"
  raw=$(mktemp)
  printf 'v\ny\ny\ny\n' | bash <(curl -sL https://run.NodeQuality.com) > "$raw" 2>&1
  links=$(grep -aoE 'https://nodequality\.com/r/[A-Za-z0-9]+' "$raw" | awk '!seen[$0]++')
  {
    echo "===== NodeQuality Test Links $(date '+%Y-%m-%d %H:%M:%S') ====="
    echo "Command: printf 'v\\ny\\ny\\ny\\n' | bash <(curl -sL https://run.NodeQuality.com)"
    echo
    if [ -n "$links" ]; then
      echo "$links"
    else
      echo "No nodequality.com result link was extracted."
    fi
    echo
    echo "===== NodeQuality Testfinished $(date '+%Y-%m-%d %H:%M:%S') ====="
  } > "$fpath"
  rm -f "$raw"
  retain=$(grep -E '^RETAIN_DAYS=' "$NQ_SETTING" 2>/dev/null | cut -d= -f2); retain=${retain:-30}
  find "$NQ_DATA" -type f -name '*.log' -mtime +"$retain" -delete 2>/dev/null
  echo "Saved: $fpath"
}

# ============================================================
#  systemd management
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
  ok "Scheduled Ping Monitor enabled"
}
disable_ping_service(){
  systemctl disable --now sshtool-ping.service 2>/dev/null
  rm -f /etc/systemd/system/sshtool-ping.service
  systemctl daemon-reload
  ok "Scheduled Ping Monitor disabled"
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
RandomizedDelaySec=30min
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  if ! systemctl enable --now sshtool-ipquality.timer; then
    err "Failed to enable Scheduled IP Quality Test. Please run: systemctl status sshtool-ipquality.timer"
    return 1
  fi
  ok "Scheduled IP Quality Test enabled (daily ${hour}:${minute} +30 minutes)"
}
disable_ipquality_timer(){
  systemctl disable --now sshtool-ipquality.timer 2>/dev/null
  rm -f /etc/systemd/system/sshtool-ipquality.timer /etc/systemd/system/sshtool-ipquality.service
  systemctl daemon-reload
  ok "Scheduled IP Quality Test disabled"
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
RandomizedDelaySec=30min
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  if ! systemctl enable --now sshtool-yabs.timer; then
    err "Failed to enable Scheduled YABS Test. Please run: systemctl status sshtool-yabs.timer"
    return 1
  fi
  ok "Scheduled YABS Test enabled (daily ${hour}:${minute} +30 minutes)"
}
disable_yabs_timer(){
  systemctl disable --now sshtool-yabs.timer 2>/dev/null
  rm -f /etc/systemd/system/sshtool-yabs.timer /etc/systemd/system/sshtool-yabs.service
  systemctl daemon-reload
  ok "Scheduled YABS Test disabled"
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
RandomizedDelaySec=30min
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  if ! systemctl enable --now sshtool-bench.timer; then
    err "Failed to enable Scheduled Bench.sh Test. Please run: systemctl status sshtool-bench.timer"
    return 1
  fi
  ok "Scheduled Bench.sh Test enabled (daily ${hour}:${minute} +30 minutes)"
}
disable_bench_timer(){
  systemctl disable --now sshtool-bench.timer 2>/dev/null
  rm -f /etc/systemd/system/sshtool-bench.timer /etc/systemd/system/sshtool-bench.service
  systemctl daemon-reload
  ok "Scheduled Bench.sh Test disabled"
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
RandomizedDelaySec=30min
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  if ! systemctl enable --now sshtool-nodequality.timer; then
    err "Failed to enable Scheduled NodeQuality Test. Please run: systemctl status sshtool-nodequality.timer"
    return 1
  fi
  ok "Scheduled NodeQuality Test enabled (starting today, every ${interval} days: ${hour}:${minute} +30 minutes + same day ${ehour}:${eminute} +30 minutes)"
}
disable_nq_timer(){
  systemctl disable --now sshtool-nodequality.timer 2>/dev/null
  rm -f /etc/systemd/system/sshtool-nodequality.timer /etc/systemd/system/sshtool-nodequality.service
  systemctl daemon-reload
  ok "Scheduled NodeQuality Test disabled"
}

# ============================================================
#  Ping result view
# ============================================================
# Filter data for the selected time range into a temp file
filter_to_tmp(){ # filter_to_tmp csvfile range(1h/1d/all) output tmp
  local csv="$1" range="$2" out="$3"
  : > "$out"
  [ -f "$csv" ] || return
  if [ "$range" = "all" ]; then cp "$csv" "$out"; return; fi
  local cutoff
  if [ "$range" = "1h" ]; then cutoff=$(date -d '1 hour ago' '+%Y-%m-%d %H:%M:%S')
  else cutoff=$(date -d '1 day ago' '+%Y-%m-%d %H:%M:%S'); fi
  awk -F, -v c="$cutoff" '$1 >= c' "$csv" > "$out"
}

# A: Trend bar + statistics
view_A(){ # view_A tmpfile target name
  local tmp="$1" name="$2"
  local total ok_c loss_c
  total=$(wc -l < "$tmp"); total=${total:-0}
  if [ "$total" -eq 0 ]; then echo "  (No data)"; return; fi
  ok_c=$(awk -F, '$4=="OK"' "$tmp" | wc -l)
  loss_c=$((total-ok_c))
  local avg min max
  avg=$(awk -F, '$4=="OK"&&$3!=""{s+=$3;n++} END{if(n>0)printf "%.1f",s/n; else print "-"}' "$tmp")
  min=$(awk -F, '$4=="OK"&&$3!=""{if(m==""||$3<m)m=$3} END{print (m==""?"-":m)}' "$tmp")
  max=$(awk -F, '$4=="OK"&&$3!=""{if($3>m)m=$3} END{print (m==""?"-":m)}' "$tmp")
  local loss_pct; loss_pct=$(awk -v l="$loss_c" -v t="$total" 'BEGIN{printf "%.0f", (t>0?l*100/t:0)}')
  echo -e "  ${C_BOLD}${name}${C_RESET}"
  echo -e "  samples:${total}  loss:${loss_pct}%  latency(ms) avg:${avg} min:${min} max:${max}"
  # Trend bar: one colored block per sample, latest 60 samples
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
  echo -e "  Recent trend: ${bars}${C_RESET}"
  echo -e "  ${C_GRN}|green<80${C_RESET} ${C_YEL}|yellow80-200${C_RESET} ${C_RED}|red>200/x timeout${C_RESET}"
}

# B: Numbered segments by hour; fill SEG_* arrays for drill-down
declare -a SEG_LABEL SEG_START SEG_END
view_B(){ # view_B tmpfile
  SEG_LABEL=(); SEG_START=(); SEG_END=()
  local tmp="$1"
  [ -s "$tmp" ] || { echo "  (No data)"; return; }
  # group by "year-month-day hour"
  local segs; segs=$(awk -F, '{print substr($1,1,13)}' "$tmp" | sort -u)
  local i=0 seg cnt okc loss avg dot col
  echo -e "  ${C_BOLD}Segment overview (by hour):${C_RESET}"
  while IFS= read -r seg; do
    [ -z "$seg" ] && continue
    cnt=$(awk -F, -v s="$seg" 'substr($1,1,13)==s' "$tmp" | wc -l)
    okc=$(awk -F, -v s="$seg" 'substr($1,1,13)==s && $4=="OK"' "$tmp" | wc -l)
    loss=$((cnt-okc))
    avg=$(awk -F, -v s="$seg" 'substr($1,1,13)==s && $4=="OK" && $3!=""{x+=$3;n++} END{if(n>0)printf "%.0f",x/n; else print "-"}' "$tmp")
    # Dot color: loss -> red, avg>200 -> red, >80 -> yellow, otherwise green
    if [ "$loss" -gt 0 ]; then col="$C_RED"
    elif [ "$avg" = "-" ]; then col="$C_RED"
    else col=$(awk -v a="$avg" 'BEGIN{if(a<80)print"\033[32m";else if(a<=200)print"\033[33m";else print"\033[31m"}')
    fi
    i=$((i+1))
    SEG_LABEL[$i]="$seg"; SEG_START[$i]="$seg"
    printf "  %b●%b %d) %s  samples:%d loss:%d avg:%sms\n" "$col" "$C_RESET" "$((i+1))" "$seg" "$cnt" "$loss" "$avg"
  done <<< "$segs"
  SEG_COUNT=$i
}

# Drill into segment details (vertical, with colored dots)
drill_segment(){ # drill_segment tmpfile segment label
  local tmp="$1" seg="$2"
  clear
  echo -e "${C_BOLD}== Details: ${seg} ==${C_RESET}"
  echo "  Time                  Target          Latency Status"
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

ping_view_one(){ # ping_view_one csvfile target name range
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
    echo "  Enter segment number to view details, 0) Back"
    read -rp "Choice: " sel
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
#  Ping menu
# ============================================================
menu_ping_view(){
  while true; do
    clear
    echo -e "${C_BOLD}== View Ping Results ==${C_RESET}"
    # Select time range
    echo "  Select time range:"
    echo "  1) Last 1 hour"
    echo "  2) Last 1 day"
    echo "  3) All"
    echo "  0) Back"
    read -rp "Choice: " r
    local range
    case "$r" in
      1) range="1h";; 2) range="1d";; 3) range="all";;
      0|"") return;; *) return;;
    esac
    # List targets
    while true; do
      clear
      echo -e "${C_BOLD}== Select target (${range}) ==${C_RESET}"
      local -a tgts=() notes=()
      local idx=0 ip note
      if [ -s "$PING_CONF" ]; then
        while IFS='|' read -r ip note; do
          [ -z "$ip" ] && continue
          idx=$((idx+1)); tgts+=("$ip"); notes+=("$note")
        done < "$PING_CONF"
      fi
      if [ "$idx" -eq 0 ]; then echo "No Ping targets yet."; pause; return; fi
      echo -e "  ${C_CYN}1) All targets - overview${C_RESET}"
      local k; for k in $(seq 0 $((idx-1))); do
        printf "  %d) %s %s\n" "$((k+2))" "${tgts[$k]}" "${notes[$k]:+(${notes[$k]})}"
      done
      echo "  0) Back"
      read -rp "Select number: " sel
      case "$sel" in
        0|"") break;;
        1)
          clear
          echo -e "${C_BOLD}== All targets - overview (${range}) ==${C_RESET}\n"
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
  echo -e "${C_BOLD}== Add Ping Target ==${C_RESET}"
  read -rp "Enter IP/domain (press Enter to cancel): " ip
  [ -z "$ip" ] && return
  read -rp "Note (optional): " note
  echo "${ip}|${note}" >> "$PING_CONF"
  ok "Added: ${ip}"
  pause
}

menu_ping_settings(){
  while true; do
    clear
    init_dirs
    local interval retain
    interval=$(grep -E '^INTERVAL=' "$PING_SETTING" | cut -d= -f2)
    retain=$(grep -E '^RETAIN_DAYS=' "$PING_SETTING" | cut -d= -f2)
    echo -e "${C_BOLD}== Ping Settings ==${C_RESET}"
    echo "  Current: ping every ${interval} seconds, keep ${retain} days"
    echo "  1) Change ping interval (seconds)"
    echo "  2) Change retention days"
    echo "  3) Manage target notes/delete"
    echo "  0) Back"
    read -rp "Choice: " s
    case "$s" in
      1) read -rp "New interval (seconds): " v
         if [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -gt 0 ]; then
           sed -i "s/^INTERVAL=.*/INTERVAL=${v}/" "$PING_SETTING"; ok "Updated"
         else err "Invalid value"; fi; sleep 1;;
      2) read -rp "New retention days: " v
         if [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -gt 0 ]; then
           sed -i "s/^RETAIN_DAYS=.*/RETAIN_DAYS=${v}/" "$PING_SETTING"; ok "Updated"
         else err "Invalid value"; fi; sleep 1;;
      3) menu_ping_target_manage;;
      0|"") return;;
      *) return;;
    esac
  done
}

menu_ping_target_manage(){
  while true; do
    clear
    echo -e "${C_BOLD}== Manage Targets ==${C_RESET}"
    local -a tgts=() notes=()
    local idx=0 ip note
    if [ -s "$PING_CONF" ]; then
      while IFS='|' read -r ip note; do
        [ -z "$ip" ] && continue
        idx=$((idx+1)); tgts+=("$ip"); notes+=("$note")
      done < "$PING_CONF"
    fi
    if [ "$idx" -eq 0 ]; then echo "No targets yet."; pause; return; fi
    local k; for k in $(seq 0 $((idx-1))); do
      printf "  %d) %s %s\n" "$((k+1))" "${tgts[$k]}" "${notes[$k]:+(${notes[$k]})}"
    done
    echo "  0) Back"
    read -rp "Select a number to edit, 0 to go back: " sel
    case "$sel" in
      0|"") return;;
      *)
        if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le "$idx" ]; then
          local cur="${tgts[$((sel-1))]}"
          echo "  1) Edit note  2) Delete  0) Cancel"
          read -rp "Action: " op
          case "$op" in
            1) read -rp "New note: " nn
               sed -i "s#^${cur}|.*#${cur}|${nn}#" "$PING_CONF"; ok "Note updated"; sleep 1;;
            2) sed -i "\#^${cur}|#d" "$PING_CONF"; ok "Deleted"; sleep 1;;
            *) :;;
          esac
        else return; fi;;
    esac
  done
}

menu_ping(){
  while true; do
    clear
    echo -e "${C_BOLD}===== Scheduled Ping Monitor =====${C_RESET}  Status: $(ping_status_text)"
    echo "  1) View results"
    echo "  2) Add target"
    echo "  3) Settings (interval/retention/notes)"
    echo "  4) Enable monitor"
    echo "  5) Disable monitor"
    echo "  0) Back to main menu"
    read -rp "Choice: " s
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
#  IP Quality menu
# ============================================================
# Single report view + long-term keep management
ipq_view_one(){ # ipq_view_one filepath
  local fpath="$1"
  while true; do
    clear
    strip_clear "$fpath"
    echo
    echo "  ----------------------------------------------"
    # Detect current directory and show matching actions
    if [ "$(dirname "$fpath")" = "$IPQ_KEEP" ]; then
      echo -e "  Current status: ${C_YEL}[Keep forever]${C_RESET}"
      echo "  1) Cancel long-term keep (move back to normal, managed by retention days)"
    else
      echo -e "  Current status: ${C_GRY}Normal (auto cleanup when expired)${C_RESET}"
      echo "  1) Set long-term keep (never auto-delete)"
    fi
    echo "  0) Back"
    read -rp "Choice: " act
    case "$act" in
      1)
        local base; base="$(basename "$fpath")"
        if [ "$(dirname "$fpath")" = "$IPQ_KEEP" ]; then
          mv -f "$fpath" "${IPQ_DATA}/${base}" && { ok "Long-term keep canceled"; fpath="${IPQ_DATA}/${base}"; }
        else
          mv -f "$fpath" "${IPQ_KEEP}/${base}" && { ok "Set to long-term keep"; fpath="${IPQ_KEEP}/${base}"; }
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
    echo -e "${C_BOLD}== IP Quality Test Results ==${C_RESET}"
    local -a files=() iskeep=()
    local idx=0 line p
    # List both data/ and keep/ logs, merged by modification time descending
    # Output format: <timestamp>\t<full path> for unified sorting
    while IFS=$'\t' read -r _ p; do
      [ -z "$p" ] && continue
      idx=$((idx+1)); files+=("$p")
      if [ "$(dirname "$p")" = "$IPQ_KEEP" ]; then iskeep+=("1"); else iskeep+=("0"); fi
    done < <( { ls -1t "${IPQ_DATA}"/*.log "${IPQ_KEEP}"/*.log 2>/dev/null | while IFS= read -r p; do
                 [ -e "$p" ] && printf '%s\t%s\n' "$(stat -c %Y "$p")" "$p"
               done; } | sort -t$'\t' -k1,1nr )
    if [ "$idx" -eq 0 ]; then echo "No test results yet."; pause; return; fi
    echo -e "  ${C_CYN}1) All records - show in order${C_RESET}"
    local k tag
    for k in $(seq 0 $((idx-1))); do
      if [ "${iskeep[$k]}" = "1" ]; then tag=" ${C_YEL}[permanent]${C_RESET}"; else tag=""; fi
      printf "  %d) %s%b\n" "$((k+2))" "$(basename "${files[$k]}" .log)" "$tag"
    done
    echo "  0) Back"
    read -rp "Select number: " sel
    case "$sel" in
      0|"") return;;
      1)
        clear
        local j t2
        # View all: oldest records are shown first, newest last.
        # files[] were generated sorted by mtime descending; iterate idx-1 -> 0 here.
        for ((j=idx-1; j>=0; j--)); do
          if [ "${iskeep[$j]}" = "1" ]; then t2=" [permanent]"; else t2=""; fi
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
    echo -e "${C_BOLD}== IP Quality Settings ==${C_RESET}"
    echo "  Current schedule: daily ${hour}:${minute} +30 minutes"
    echo "  Result retention: ${retain} days"
    echo
    echo "  Settings guide: only numbers are needed here."
    echo "  Example: to set it to 3:00 AM, choose 1, then enter hour 3 and minute 0."
    echo "        Because +30 minutes is enabled, it will run randomly between 03:00 and 03:30."
    echo
    echo "  1) Change schedule time (default 03:00 +30 minutes)"
    echo "  2) Change retention days"
    echo "  0) Back"
    read -rp "Choice: " s
    case "$s" in
      1)
        echo
        echo "Enter the center time using numbers only; do not enter a colon."
        echo "Example: 03:00 -> hour 3, minute 0"
        local nh nm
        nh=$(read_int_range "Hour 0-23" "$hour" 0 23) || { sleep 1; continue; }
        nm=$(read_int_range "Minute 0-59" "$minute" 0 59) || { sleep 1; continue; }
        printf 'HOUR=%02d
MINUTE=%02d
RETAIN_DAYS=%s
' "$nh" "$nm" "$retain" > "$IPQ_SETTING"
        ok "Set to daily $(printf '%02d' "$nh"):$(printf '%02d' "$nm") +30 minutes"
        if ipquality_enabled; then install_ipquality_timer >/dev/null; ok "systemd timer updated"; fi
        sleep 1;;
      2)
        echo
        echo "Enter result retention days using numbers only."
        echo "Example: enter 30 to keep 30 days; enter 90 to keep 90 days."
        local nr
        nr=$(read_positive_int "Retention days" "$retain") || { sleep 1; continue; }
        printf 'HOUR=%s
MINUTE=%s
RETAIN_DAYS=%s
' "$hour" "$minute" "$nr" > "$IPQ_SETTING"
        ok "Retention set to ${nr} days"
        sleep 1;;
      0|"") return;;
      *) return;;
    esac
  done
}

menu_ipq(){
  while true; do
    clear
    echo -e "${C_BOLD}===== Scheduled IP Quality Test =====${C_RESET}  Status: $(ipq_status_text)"
    echo "  1) View results"
    echo "  2) Enable schedule (default daily $(ipq_hour):$(ipq_minute) +30 minutes)"
    echo "  3) Run once now"
    echo "  4) Settings"
    echo "  5) Disable schedule"
    echo "  0) Back to main menu"
    read -rp "Choice: " s
    case "$s" in
      1) menu_ipq_view;;
      2) install_ipquality_timer; pause;;
      3) echo "Testing, please wait..."; run_ipquality_once; ok "Done"; pause;;
      4) menu_ipq_settings;;
      5) disable_ipquality_timer; pause;;
      0|"") return;;
      *) return;;
    esac
  done
}

# ============================================================
#  YABS menu
# ============================================================
yabs_view_one(){
  local fpath="$1"
  while true; do
    clear
    cat "$fpath"
    echo
    echo "  ----------------------------------------------"
    if [ "$(dirname "$fpath")" = "$YABS_KEEP" ]; then
      echo -e "  Current status: ${C_YEL}[Keep forever]${C_RESET}"
      echo "  1) Cancel long-term keep (move back to normal, managed by retention days)"
    else
      echo -e "  Current status: ${C_GRY}Normal (auto cleanup when expired)${C_RESET}"
      echo "  1) Set long-term keep (never auto-delete)"
    fi
    echo "  0) Back"
    read -rp "Choice: " act
    case "$act" in
      1)
        local base; base="$(basename "$fpath")"
        if [ "$(dirname "$fpath")" = "$YABS_KEEP" ]; then
          mv -f "$fpath" "${YABS_DATA}/${base}" && { ok "Long-term keep canceled"; fpath="${YABS_DATA}/${base}"; }
        else
          mv -f "$fpath" "${YABS_KEEP}/${base}" && { ok "Set to long-term keep"; fpath="${YABS_KEEP}/${base}"; }
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
    echo -e "${C_BOLD}== YABS Test Results ==${C_RESET}"
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
    if [ "$idx" -eq 0 ]; then echo "No YABS test results yet."; pause; return; fi
    echo -e "  ${C_CYN}1) All records - show in order${C_RESET}"
    local k tag
    for k in $(seq 0 $((idx-1))); do
      if [ "${iskeep[$k]}" = "1" ]; then tag=" ${C_YEL}[permanent]${C_RESET}"; else tag=""; fi
      printf "  %d) %s%b
" "$((k+2))" "$(basename "${files[$k]}" .log)" "$tag"
    done
    echo "  0) Back"
    read -rp "Select number: " sel
    case "$sel" in
      0|"") return;;
      1)
        clear
        local j t2
        # View all: oldest records are shown first, newest last.
        # files[] were generated sorted by mtime descending; iterate idx-1 -> 0 here.
        for ((j=idx-1; j>=0; j--)); do
          if [ "${iskeep[$j]}" = "1" ]; then t2=" [permanent]"; else t2=""; fi
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
    echo -e "${C_BOLD}== YABS Settings ==${C_RESET}"
    echo "  Current schedule: daily ${hour}:${minute} +30 minutes"
    echo "  Result retention: ${retain} days"
    echo
    echo "  Settings guide: only numbers are needed here."
    echo "  Example: to set it to 4:00 AM, choose 1, then enter hour 4 and minute 0."
    echo "        Because +30 minutes is enabled, it will run randomly between 04:00 and 04:30."
    echo
    echo "  1) Change schedule time (default 04:00 +30 minutes)"
    echo "  2) Change retention days"
    echo "  0) Back"
    read -rp "Choice: " s
    case "$s" in
      1)
        echo
        echo "Enter the center time using numbers only; do not enter a colon."
        echo "Example: 04:00 -> hour 4, minute 0"
        local nh nm
        nh=$(read_int_range "Hour 0-23" "$hour" 0 23) || { sleep 1; continue; }
        nm=$(read_int_range "Minute 0-59" "$minute" 0 59) || { sleep 1; continue; }
        printf 'HOUR=%02d
MINUTE=%02d
RETAIN_DAYS=%s
' "$nh" "$nm" "$retain" > "$YABS_SETTING"
        ok "Set to daily $(printf '%02d' "$nh"):$(printf '%02d' "$nm") +30 minutes"
        if yabs_enabled; then install_yabs_timer >/dev/null; ok "systemd timer updated"; fi
        sleep 1;;
      2)
        echo
        echo "Enter result retention days using numbers only."
        echo "Example: enter 30 to keep 30 days; enter 90 to keep 90 days."
        local nr
        nr=$(read_positive_int "Retention days" "$retain") || { sleep 1; continue; }
        printf 'HOUR=%s
MINUTE=%s
RETAIN_DAYS=%s
' "$hour" "$minute" "$nr" > "$YABS_SETTING"
        ok "Retention set to ${nr} days"
        sleep 1;;
      0|"") return;;
      *) return;;
    esac
  done
}

menu_yabs(){
  while true; do
    clear
    echo -e "${C_BOLD}===== Scheduled YABS Test =====${C_RESET}  Status: $(yabs_status_text)"
    echo "  1) View results"
    echo "  2) Enable schedule (default daily $(yabs_hour):$(yabs_minute) +30 minutes)"
    echo "  3) Run once now"
    echo "  4) Settings"
    echo "  5) Disable schedule"
    echo "  0) Back to main menu"
    read -rp "Choice: " s
    case "$s" in
      1) menu_yabs_view;;
      2) install_yabs_timer; pause;;
      3) echo "YABS test running, please wait..."; run_yabs_once; ok "Done"; pause;;
      4) menu_yabs_settings;;
      5) disable_yabs_timer; pause;;
      0|"") return;;
      *) return;;
    esac
  done
}


# ============================================================
#  Bench.sh Testmenu
# ============================================================
bench_view_one(){
  local fpath="$1"
  while true; do
    clear
    cat "$fpath"
    echo
    echo "  ----------------------------------------------"
    if [ "$(dirname "$fpath")" = "$BENCH_KEEP" ]; then
      echo -e "  Current status: ${C_YEL}[Keep forever]${C_RESET}"
      echo "  1) Cancel long-term keep (move back to normal, managed by retention days)"
    else
      echo -e "  Current status: ${C_GRY}Normal (auto cleanup when expired)${C_RESET}"
      echo "  1) Set long-term keep (never auto-delete)"
    fi
    echo "  0) Back"
    read -rp "Choice: " act
    case "$act" in
      1)
        local base; base="$(basename "$fpath")"
        if [ "$(dirname "$fpath")" = "$BENCH_KEEP" ]; then
          mv -f "$fpath" "${BENCH_DATA}/${base}" && { ok "Long-term keep canceled"; fpath="${BENCH_DATA}/${base}"; }
        else
          mv -f "$fpath" "${BENCH_KEEP}/${base}" && { ok "Set to long-term keep"; fpath="${BENCH_KEEP}/${base}"; }
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
    echo -e "${C_BOLD}== Bench.sh Test Results ==${C_RESET}"
    local -a files=() iskeep=()
    local idx=0 p
    while IFS=$'\t' read -r _ p; do
      [ -z "$p" ] && continue
      idx=$((idx+1)); files+=("$p")
      if [ "$(dirname "$p")" = "$BENCH_KEEP" ]; then iskeep+=("1"); else iskeep+=("0"); fi
    done < <( { ls -1t "${BENCH_DATA}"/*.log "${BENCH_KEEP}"/*.log 2>/dev/null | while IFS= read -r p; do
                 [ -e "$p" ] && printf '%s\t%s\n' "$(stat -c %Y "$p")" "$p"
               done; } | sort -t$'\t' -k1,1nr )
    if [ "$idx" -eq 0 ]; then echo "No Bench.sh test results yet."; pause; return; fi
    echo -e "  ${C_CYN}1) All records - show in order${C_RESET}"
    local k tag
    for k in $(seq 0 $((idx-1))); do
      if [ "${iskeep[$k]}" = "1" ]; then tag=" ${C_YEL}[permanent]${C_RESET}"; else tag=""; fi
      printf "  %d) %s%b\n" "$((k+2))" "$(basename "${files[$k]}" .log)" "$tag"
    done
    echo "  0) Back"
    read -rp "Select number: " sel
    case "$sel" in
      0|"") return;;
      1)
        clear
        local j t2
        # View all: oldest records are shown first, newest last.
        # files[] were generated sorted by mtime descending; iterate idx-1 -> 0 here.
        for ((j=idx-1; j>=0; j--)); do
          if [ "${iskeep[$j]}" = "1" ]; then t2=" [permanent]"; else t2=""; fi
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
    echo -e "${C_BOLD}== Bench.sh Settings ==${C_RESET}"
    echo "  Current schedule: daily ${hour}:${minute} +30 minutes"
    echo "  Result retention: ${retain} days"
    echo
    echo "  Settings guide: only numbers are needed here."
    echo "  Example: to set it to 5:00 AM, choose 1, then enter hour 5 and minute 0."
    echo "        Because +30 minutes is enabled, it will run randomly between 05:00 and 05:30."
    echo
    echo "  1) Change schedule time (default 05:00 +30 minutes)"
    echo "  2) Change retention days"
    echo "  0) Back"
    read -rp "Choice: " s
    case "$s" in
      1)
        echo
        echo "Enter the center time using numbers only; do not enter a colon."
        echo "Example: 05:00 -> hour 5, minute 0"
        local nh nm
        nh=$(read_int_range "Hour 0-23" "$hour" 0 23) || { sleep 1; continue; }
        nm=$(read_int_range "Minute 0-59" "$minute" 0 59) || { sleep 1; continue; }
        printf 'HOUR=%02d
MINUTE=%02d
RETAIN_DAYS=%s
' "$nh" "$nm" "$retain" > "$BENCH_SETTING"
        ok "Set to daily $(printf '%02d' "$nh"):$(printf '%02d' "$nm") +30 minutes"
        if bench_enabled; then install_bench_timer >/dev/null; ok "systemd timer updated"; fi
        sleep 1;;
      2)
        echo
        echo "Enter result retention days using numbers only."
        echo "Example: enter 30 to keep 30 days; enter 90 to keep 90 days."
        local nr
        nr=$(read_positive_int "Retention days" "$retain") || { sleep 1; continue; }
        printf 'HOUR=%s
MINUTE=%s
RETAIN_DAYS=%s
' "$hour" "$minute" "$nr" > "$BENCH_SETTING"
        ok "Retention set to ${nr} days"
        sleep 1;;
      0|"") return;;
      *) return;;
    esac
  done
}

menu_bench(){
  while true; do
    clear
    echo -e "${C_BOLD}===== Scheduled Bench.sh Test =====${C_RESET}  Status: $(bench_status_text)"
    echo "  1) View results"
    echo "  2) Enable schedule (default daily $(bench_hour):$(bench_minute) +30 minutes)"
    echo "  3) Run once now"
    echo "  4) Settings"
    echo "  5) Disable schedule"
    echo "  0) Back to main menu"
    read -rp "Choice: " s
    case "$s" in
      1) menu_bench_view;;
      2) install_bench_timer; pause;;
      3) echo "Bench.sh test running, please wait..."; run_bench_once; ok "Done"; pause;;
      4) menu_bench_settings;;
      5) disable_bench_timer; pause;;
      0|"") return;;
      *) return;;
    esac
  done
}


# ============================================================
#  NodeQuality menu
# ============================================================
nq_view_one(){
  local fpath="$1"
  while true; do
    clear
    cat "$fpath"
    echo
    echo "  ----------------------------------------------"
    if [ "$(dirname "$fpath")" = "$NQ_KEEP" ]; then
      echo -e "  Current status: ${C_YEL}[Keep forever]${C_RESET}"
      echo "  1) Cancel long-term keep (move back to normal, managed by retention days)"
    else
      echo -e "  Current status: ${C_GRY}Normal (auto cleanup when expired)${C_RESET}"
      echo "  1) Set long-term keep (never auto-delete)"
    fi
    echo "  0) Back"
    read -rp "Choice: " act
    case "$act" in
      1)
        local base; base="$(basename "$fpath")"
        if [ "$(dirname "$fpath")" = "$NQ_KEEP" ]; then
          mv -f "$fpath" "${NQ_DATA}/${base}" && { ok "Long-term keep canceled"; fpath="${NQ_DATA}/${base}"; }
        else
          mv -f "$fpath" "${NQ_KEEP}/${base}" && { ok "Set to long-term keep"; fpath="${NQ_KEEP}/${base}"; }
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
    echo -e "${C_BOLD}== NodeQuality Result Links ==${C_RESET}"
    local -a files=() iskeep=()
    local idx=0 p
    while IFS=$'\t' read -r _ p; do
      [ -z "$p" ] && continue
      idx=$((idx+1)); files+=("$p")
      if [ "$(dirname "$p")" = "$NQ_KEEP" ]; then iskeep+=("1"); else iskeep+=("0"); fi
    done < <( { ls -1t "${NQ_DATA}"/*.log "${NQ_KEEP}"/*.log 2>/dev/null | while IFS= read -r p; do
                 [ -e "$p" ] && printf '%s\t%s\n' "$(stat -c %Y "$p")" "$p"
               done; } | sort -t$'\t' -k1,1nr )
    if [ "$idx" -eq 0 ]; then echo "No NodeQuality result links yet."; pause; return; fi
    echo -e "  ${C_CYN}1) All records - show in order${C_RESET}"
    local k tag
    for k in $(seq 0 $((idx-1))); do
      if [ "${iskeep[$k]}" = "1" ]; then tag=" ${C_YEL}[permanent]${C_RESET}"; else tag=""; fi
      printf "  %d) %s%b\n" "$((k+2))" "$(basename "${files[$k]}" .log)" "$tag"
    done
    echo "  0) Back"
    read -rp "Select number: " sel
    case "$sel" in
      0|"") return;;
      1)
        clear
        local j t2
        for ((j=idx-1; j>=0; j--)); do
          if [ "${iskeep[$j]}" = "1" ]; then t2=" [permanent]"; else t2=""; fi
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
    echo -e "${C_BOLD}== NodeQuality Settings ==${C_RESET}"
    echo "  Current cycle: starts from ${start_date}, test once every ${interval} days"
    echo "  Current schedule: same day ${hour}:${minute} +30 minutes + evening peak ${ehour}:${eminute} +30 minutes"
    echo "  Result retention: ${retain} days"
    echo
    echo "  Settings guide: only numbers are needed here."
    echo "  Example 1: to test every 7 days, choose 1 and enter 7."
    echo "  Example 2: to test at 6:00 AM, choose 2, then enter hour 6 and minute 0."
    echo "  Example 3: to test at evening peak 22:00, choose 3, then enter hour 22 and minute 0."
    echo "  Note: +30 minutes means 06:00 runs randomly between 06:00 and 06:30."
    echo
    echo "  1) Change test interval days (default 7)"
    echo "  2) Change daytime test time (default 06:00 +30 minutes)"
    echo "  3) Change evening peak test time (default 22:00 +30 minutes)"
    echo "  4) Change retention days"
    echo "  0) Back"
    read -rp "Choice: " s
    case "$s" in
      1)
        echo
        echo "Enter test interval days using numbers only."
        echo "Example: enter 7 for every 7 days; enter 3 for every 3 days."
        local ni
        ni=$(read_positive_int "Interval days" "$interval") || { sleep 1; continue; }
        nq_write_settings "$ni" "$hour" "$minute" "$ehour" "$eminute" "$start_date" "$retain"
        ok "Set to test every ${ni} days"
        if nq_enabled; then install_nq_timer >/dev/null; ok "systemd timer updated, and the cycle restarted from today"; fi
        sleep 1;;
      2)
        echo
        echo "Enter the daytime center time using numbers only; do not enter a colon."
        echo "Example: 06:00 -> hour 6, minute 0; actual run is random between 06:00 and 06:30."
        local nh nm
        nh=$(read_int_range "Hour 0-23" "$hour" 0 23) || { sleep 1; continue; }
        nm=$(read_int_range "Minute 0-59" "$minute" 0 59) || { sleep 1; continue; }
        nq_write_settings "$interval" "$(printf '%02d' "$nh")" "$(printf '%02d' "$nm")" "$ehour" "$eminute" "$start_date" "$retain"
        ok "Daytime test set to $(printf '%02d' "$nh"):$(printf '%02d' "$nm") +30 minutes"
        if nq_enabled; then install_nq_timer >/dev/null; ok "systemd timer updated, and the cycle restarted from today"; fi
        sleep 1;;
      3)
        echo
        echo "Enter the evening peak center time using numbers only; do not enter a colon."
        echo "Example: 22:00 -> hour 22, minute 0; actual run is random between 21:30 and 22:30."
        local nh nm
        nh=$(read_int_range "Hour 0-23" "$ehour" 0 23) || { sleep 1; continue; }
        nm=$(read_int_range "Minute 0-59" "$eminute" 0 59) || { sleep 1; continue; }
        nq_write_settings "$interval" "$hour" "$minute" "$(printf '%02d' "$nh")" "$(printf '%02d' "$nm")" "$start_date" "$retain"
        ok "Evening peak test set to $(printf '%02d' "$nh"):$(printf '%02d' "$nm") +30 minutes"
        if nq_enabled; then install_nq_timer >/dev/null; ok "systemd timer updated, and the cycle restarted from today"; fi
        sleep 1;;
      4)
        echo
        echo "Enter result retention days using numbers only."
        echo "Example: enter 30 to keep 30 days; enter 90 to keep 90 days."
        local nr
        nr=$(read_positive_int "Retention days" "$retain") || { sleep 1; continue; }
        nq_write_settings "$interval" "$hour" "$minute" "$ehour" "$eminute" "$start_date" "$nr"
        ok "Retention set to ${nr} days"
        sleep 1;;
      0|"") return;;
      *) return;;
    esac
  done
}

menu_nq(){
  while true; do
    clear
    echo -e "${C_BOLD}===== Scheduled NodeQuality Test =====${C_RESET}  Status: $(nq_status_text)"
    echo "  1) View results"
    echo "  2) Enable schedule (default every $(nq_interval_days) days: $(nq_hour):$(nq_minute) +30 minutes + same day $(nq_evening_hour):$(nq_evening_minute) +30 minutes)"
    echo "  3) Run once now"
    echo "  4) Settings"
    echo "  5) Disable schedule"
    echo "  0) Back to main menu"
    read -rp "Choice: " s
    case "$s" in
      1) menu_nq_view;;
      2) install_nq_timer; pause;;
      3) echo "NodeQuality test running, please wait..."; run_nq_once; ok "Done; only nodequality.com result links were saved"; pause;;
      4) menu_nq_settings;;
      5) disable_nq_timer; pause;;
      0|"") return;;
      *) return;;
    esac
  done
}


menu_start_guide(){
  clear
  echo -e "${C_BOLD}===== Setup Wizard =====${C_RESET}"
  echo
  echo "How to use: "
  echo "  - Press Enter: enable recommended defaults"
  echo "  - Enter 1: guided setup per feature; for each item enter number 1=enable, 2=do not enable"
  echo "  - Enter 3: enable all five features"
  echo
  echo "Recommended defaults: "
  echo "  - Scheduled IP Quality Test (daily 03:00 +30 minutes)"
  echo "  - Scheduled YABS Test (daily 04:00 +30 minutes; checks memory/swap before enabling)"
  echo
  echo "Not enabled by default; enable manually or via guided setup if needed: "
  echo "  - Scheduled Ping Monitor"
  echo "  - Scheduled Bench.sh Test (daily 05:00 +30 minutes)"
  echo "  - Scheduled NodeQuality Test (every 7 days 06:00 +30 minutes + same day 22:00 +30 minutes)"
  echo
  read -rp "Press Enter to use defaults; enter 1 for guided setup; enter 2 to cancel; enter 3 to enable all: " ans

  if [ -z "$ans" ]; then
    echo
    echo "Enabling: Scheduled IP Quality Test..."
    if install_ipquality_timer; then
      ok "Scheduled IP Quality Testenabled"
    else
      err "Scheduled IP Quality Testfailed to enable"
    fi

    echo
    echo "Enabling: Scheduled YABS Test..."
    if install_yabs_timer; then
      ok "Scheduled YABS Testenabled"
    else
      err "Scheduled YABS Testfailed to enable"
    fi

    echo
    echo -e "${C_BOLD}Wizard completed.${C_RESET}"
    echo "Defaults processed: "
    echo "  - Scheduled IP Quality Test"
    echo "  - Scheduled YABS Test"
    echo
    echo "Reminder: the other three are not enabled automatically; enable them manually from the main menu:"
    echo "  2) Scheduled Ping Monitor"
    echo "  5) Scheduled Bench.sh Test (default daily $(bench_hour):$(bench_minute) +30 minutes)"
    echo "  6) Scheduled NodeQuality Test (default every $(nq_interval_days) days $(nq_hour):$(nq_minute) +30 minutes + same day $(nq_evening_hour):$(nq_evening_minute) +30 minutes)"
    pause
    return
  fi

  if [ "$ans" = "3" ]; then
    echo
    echo -e "${C_BOLD}Enabling all five features...${C_RESET}"

    echo
    echo "Enabling: Scheduled Ping Monitor..."
    if install_ping_service; then
      ok "Scheduled Ping Monitor enabled"
    else
      err "Scheduled Ping Monitor failed to enable"
    fi

    echo
    echo "Enabling: Scheduled IP Quality Test..."
    if install_ipquality_timer; then
      ok "Scheduled IP Quality Test enabled"
    else
      err "Scheduled IP Quality Test failed to enable"
    fi

    echo
    echo "Enabling: Scheduled YABS Test..."
    if install_yabs_timer; then
      ok "Scheduled YABS Test enabled"
    else
      err "Scheduled YABS Test failed to enable"
    fi

    echo
    echo "Enabling: Scheduled Bench.sh Test..."
    if install_bench_timer; then
      ok "Scheduled Bench.sh Test enabled"
    else
      err "Scheduled Bench.sh Test failed to enable"
    fi

    echo
    echo "Enabling: Scheduled NodeQuality Test..."
    if install_nq_timer; then
      ok "Scheduled NodeQuality Test enabled"
    else
      err "Scheduled NodeQuality Test failed to enable"
    fi

    echo
    echo -e "${C_BOLD}Enable-all process completed.${C_RESET}"
    echo "Tried to enable:"
    echo "  - Scheduled Ping Monitor"
    echo "  - Scheduled IP Quality Test"
    echo "  - Scheduled YABS Test"
    echo "  - Scheduled Bench.sh Test"
    echo "  - Scheduled NodeQuality Test"
    pause
    return
  fi

  if [ "$ans" = "2" ]; then
    echo "Setup wizard canceled."
    pause
    return
  fi

  if [ "$ans" != "1" ]; then
    echo "Invalid input; returned to main menu."
    pause
    return
  fi

  clear
  echo -e "${C_BOLD}===== Per-feature setup wizard =====${C_RESET}"
  echo
  echo "Note: enter numbers only for each feature below."
  echo "  1 = Enable"
  echo "  2 = Do not enable"
  echo "  Press Enter = do not enable this item"
  echo

  local enabled_list=""
  local skipped_list=""
  local choice=""

  guide_enable_one(){
    local title="$1"
    local hint="$2"
    local cmd="$3"
    echo
    echo "Enable: ${title}"
    echo "Description: ${hint}"
    read -rp "Enter 1 to enable, 2 to skip: " choice
    case "$choice" in
      1)
        echo "Enabling: ${title}..."
        if "$cmd"; then
          ok "${title} enabled"
          enabled_list="${enabled_list}\n  - ${title}"
        else
          err "${title} failed to enable"
          skipped_list="${skipped_list}\n  - ${title} (failed to enable)"
        fi
        ;;
      2|"")
        echo "Skipped: ${title}"
        skipped_list="${skipped_list}\n  - ${title}"
        ;;
      *)
        echo "Invalid input; treated as skip: ${title}"
        skipped_list="${skipped_list}\n  - ${title}"
        ;;
    esac
  }

  guide_enable_one "Scheduled Ping Monitor" "Continuously records target latency/loss; you can add targets in the Ping menu first." install_ping_service
  guide_enable_one "Scheduled IP Quality Test" "Default: daily at 03:00 +30 minutes." install_ipquality_timer
  guide_enable_one "Scheduled YABS Test" "Default: daily at 04:00 +30 minutes; checks memory/swap before enabling." install_yabs_timer
  guide_enable_one "Scheduled Bench.sh Test" "Default: daily at 05:00 +30 minutes." install_bench_timer
  guide_enable_one "Scheduled NodeQuality Test" "Default: every 7 days; cycle starts from the day you enable it, with one run at 06:00 +30 minutes and one at 22:00 +30 minutes on the same day." install_nq_timer

  echo
  echo -e "${C_BOLD}Per-feature wizard completed.${C_RESET}"
  if [ -n "$enabled_list" ]; then
    echo "Enabled:"
    printf "%b\n" "$enabled_list"
  else
    echo "Enabled: none"
  fi
  echo
  if [ -n "$skipped_list" ]; then
    echo "Not enabled/skipped:"
    printf "%b\n" "$skipped_list"
  fi
  pause
}

# ============================================================
#  Main menu
# ============================================================
main_menu(){
  init_dirs
  while true; do
    clear
    echo -e "${C_BOLD}╔══════════════════════════════╗${C_RESET}"
    echo -e "${C_BOLD}║          Keep Your VPS Busy          ║${C_RESET}"
    echo -e "${C_BOLD}╚══════════════════════════════╝${C_RESET}"
    echo -e "  Scheduled Ping Monitor : $(ping_status_text)"
    echo -e "  Scheduled IP Quality Test : $(ipq_status_text)"
    echo -e "  Scheduled YABS Test : $(yabs_status_text)"
    echo -e "  Scheduled Bench.sh Test : $(bench_status_text)"
    echo -e "  Scheduled NodeQuality Test : $(nq_status_text)"
    echo "  ------------------------------"
    echo "  1) Setup Wizard"
    echo "  2) Scheduled Ping Monitor"
    echo "  3) Scheduled IP Quality Test (default daily $(ipq_hour):$(ipq_minute) +30 minutes)"
    echo "  4) Scheduled YABS Test (default daily $(yabs_hour):$(yabs_minute) +30 minutes)"
    echo "  5) Scheduled Bench.sh Test (default daily $(bench_hour):$(bench_minute) +30 minutes)"
    echo "  6) Scheduled NodeQuality Test (default every $(nq_interval_days) days $(nq_hour):$(nq_minute) +30 minutes + same day $(nq_evening_hour):$(nq_evening_minute) +30 minutes)"
    echo "  0) Exit"
    read -rp "Choice: " s
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
#  Entry
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
      err "Please run as root (sudo bash $0)"; exit 1
    fi
    main_menu;;
esac
