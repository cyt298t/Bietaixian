#!/usr/bin/env bash
# ============================================================
#  综合服务器工具箱 (Debian 12)
#  模块: 1) 定期 Ping 监控   2) 定期测 IP 质量
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

# ---------- 颜色 ----------
C_RESET="\033[0m"; C_RED="\033[31m"; C_GRN="\033[32m"; C_YEL="\033[33m"
C_BLU="\033[34m"; C_CYN="\033[36m"; C_BOLD="\033[1m"; C_GRY="\033[90m"

# ---------- 小工具 ----------
err(){ echo -e "${C_RED}[错误]${C_RESET} $*" >&2; }
ok(){ echo -e "${C_GRN}[成功]${C_RESET} $*"; }
pause(){ read -rp "按回车继续..." _; }
safe_name(){ echo "$1" | sed 's#[/:*?"<>| ]#_#g'; }

init_dirs(){
  mkdir -p "$PING_DATA" "$IPQ_DATA" "$IPQ_KEEP"
  [ -f "$PING_SETTING" ] || printf 'INTERVAL=60\nRETAIN_DAYS=7\n' > "$PING_SETTING"
  [ -f "$IPQ_SETTING" ]  || printf 'RETAIN_DAYS=30\n' > "$IPQ_SETTING"
  touch "$PING_CONF"
}

# ---------- 日志清洗: 只保留最后一次整屏清屏后的最终报告 ----------
# 去 spinner 动画(按 \r 取最后一帧) + 删光标定位/擦除码, 保留颜色(SGR)
strip_clear(){
  local f="$1"
  awk 'BEGIN{ esc=sprintf("%c",27); RS="^$"; }
       { buf=$0;
         # 找最后一次整屏清屏 ESC[2J 或 ESC[3J 的位置
         pat=esc "[2J"; pat3=esc "[3J";
         p=0; i=1;
         while(1){ a=index(substr(buf,i),pat); b=index(substr(buf,i),pat3);
                   pos=0; ln=0;
                   if(a>0 && (b==0 || a<b)){ pos=i+a-1; ln=length(pat); }
                   else if(b>0){ pos=i+b-1; ln=length(pat3); }
                   else break;
                   p=pos+ln; i=p; }
         if(p>0) buf=substr(buf,p);
         printf "%s", buf;
       }' "$f" \
  | awk 'BEGIN{ FS="\r" }
         { n=split($0,a,"\r"); print a[n] }' \
  | sed -E "s/\x1b\[[0-9;]*[HJKfABCDsu]//g; s/\x1b[()][AB0]//g; s/\x1b\[[0-9]*[GdX]//g"
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
  local fpath="${IPQ_DATA}/$(date '+%Y-%m-%d_%H时').log"
  { echo "===== IP质量检测 $(date '+%Y-%m-%d %H:%M:%S') ====="
    bash <(curl -sL IP.Check.Place) -y 2>&1; } > "$fpath"
  local retain; retain=$(grep -E '^RETAIN_DAYS=' "$IPQ_SETTING" 2>/dev/null | cut -d= -f2); retain=${retain:-30}
  find "$IPQ_DATA" -type f -name '*.log' -mtime +"$retain" -delete 2>/dev/null
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
  local sp; sp="$(self_path)"
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
OnCalendar=*-*-* 05:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now sshtool-ipquality.timer
  ok "定期测 IP 质量已开启 (每天 05:00)"
}
disable_ipquality_timer(){
  systemctl disable --now sshtool-ipquality.timer 2>/dev/null
  rm -f /etc/systemd/system/sshtool-ipquality.timer /etc/systemd/system/sshtool-ipquality.service
  systemctl daemon-reload
  ok "定期测 IP 质量已关闭"
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

menu_ipq(){
  while true; do
    clear
    echo -e "${C_BOLD}===== 定期测 IP 质量 =====${C_RESET}  状态: $(ipq_status_text)"
    echo "  1) 查看结果"
    echo "  2) 立即检测一次"
    echo "  3) 开启 (每天 05:00)"
    echo "  4) 关闭"
    echo "  0) 返回主菜单"
    read -rp "选择: " s
    case "$s" in
      1) menu_ipq_view;;
      2) echo "检测中, 请稍候..."; run_ipquality_once; ok "完成"; pause;;
      3) install_ipquality_timer; pause;;
      4) disable_ipquality_timer; pause;;
      0|"") return;;
      *) return;;
    esac
  done
}

# ============================================================
#  主菜单
# ============================================================
main_menu(){
  init_dirs
  while true; do
    clear
    echo -e "${C_BOLD}╔══════════════════════════════╗${C_RESET}"
    echo -e "${C_BOLD}      综合服务器工具箱 v1${C_RESET}"
    echo -e "${C_BOLD}╚══════════════════════════════╝${C_RESET}"
    echo -e "  定期 Ping 监控 : $(ping_status_text)"
    echo -e "  定期测 IP 质量 : $(ipq_status_text)"
    echo "  ------------------------------"
    echo "  1) 定期 Ping 监控"
    echo "  2) 定期测 IP 质量"
    echo "  0) 退出"
    read -rp "选择: " s
    case "$s" in
      1) menu_ping;;
      2) menu_ipq;;
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
  *)
    if [ "$(id -u)" -ne 0 ]; then
      err "请用 root 运行 (sudo bash $0)"; exit 1
    fi
    main_menu;;
esac
