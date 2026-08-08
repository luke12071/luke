#!/bin/bash
# ============================================================
# DevMon 修复脚本 — 把已安装的采集器升级为 v2 并自检排错
# 用法: sudo bash fix-devmon.sh
# 修复内容: 设备发现不再依赖 conntrack timestamp (新增 ss 兜底),
#           nft 流量解析修正, 采集错误写入 collect.log 便于定位
# ============================================================
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "[!] 请用 root 执行: sudo bash fix-devmon.sh"
  exit 1
fi

echo "==> 1/3 覆盖采集器 (v2)"
cat > /usr/local/bin/devmon.sh <<'EOF'
#!/bin/bash
# DevMon 采集器 v2 — conntrack/ss 发现设备, nftables 记账上下行, GeoIP 定位, dnsmasq DNS 统计
# 输出: /var/lib/devmon/devices.json   错误日志: /var/lib/devmon/collect.log
set -u
OUT=/var/lib/devmon/devices.json
GEO=/var/lib/devmon/geo.cache
LOG=/var/lib/devmon/collect.log
now=$(date +%s)
[ -d /var/lib/devmon ] || mkdir -p /var/lib/devmon
[ -f "$GEO" ] || : > "$GEO"
: > "$LOG"

declare -A DUR PROTO UP DOWN SEEN

# --- 1. 设备发现 + 协议 (conntrack 优先, ss 兜底) ---
while read -r proto ip; do
  [ -n "${ip:-}" ] && PROTO[$ip]="${PROTO[$ip]:-} $proto"
done < <(conntrack -L 2>>"$LOG" | awk '$1 ~ /^(tcp|udp|sctp|gre)$/ && match($0,/src=[0-9.]+/) { print $1, substr($0,RSTART+4,RLENGTH-4) }')

while read -r ip; do
  [ -n "${ip:-}" ] && PROTO[$ip]="${PROTO[$ip]:-} tcp"
done < <(ss -tnH 2>/dev/null | awk '{ split($5,a,":"); if (a[1] ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && a[1] != "0.0.0.0" && a[1] != "127.0.0.1") print a[1] }')

# --- 2. 连接时长 (conntrack timestamp, 拿不到不阻塞) ---
while read -r st ip; do
  [[ "$st" =~ ^[0-9]+$ ]] || continue
  d=$((now-st)); [ "$d" -lt 0 ] && d=0
  [ "${DUR[$ip]:-0}" -lt "$d" ] && DUR[$ip]=$d
done < <(conntrack -L -o timestamp 2>>"$LOG" | awk '
  /^\[START\]/ { if (ip != "") print $2, ip; ip=""; next }
  $1 ~ /^(tcp|udp|sctp|gre)$/ && match($0,/src=[0-9.]+/) { ip=substr($0,RSTART+4,RLENGTH-4) }')

# --- 3. 上下行流量 (nftables netmon 表) ---
if nft list map inet netmon up >/dev/null 2>&1; then
  while read -r ip bytes; do UP[$ip]=$bytes; done < <(nft list map inet netmon up   | grep -oE '[0-9.]+ counter packets [0-9]+ bytes [0-9]+' | awk '{print $1, $NF}')
  while read -r ip bytes; do DOWN[$ip]=$bytes; done < <(nft list map inet netmon down | grep -oE '[0-9.]+ counter packets [0-9]+ bytes [0-9]+' | awk '{print $1, $NF}')
else
  echo "$(date '+%F %T') 警告: nft inet netmon 表不存在，请重新执行安装脚本" >> "$LOG"
fi

for ip in "${!PROTO[@]}" "${!UP[@]}" "${!DOWN[@]}"; do SEEN[$ip]=1; done

geoip() {
  local ip=$1 line ts loc
  case "$ip" in
    10.*|192.168.*|127.*|169.254.*|100.6[4-9].*|100.7[0-9].*|100.8[0-9].*|100.9[0-9].*|100.1[0-1][0-9].*|100.12[0-7].*) echo "内网"; return;;
    172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) echo "内网"; return;;
  esac
  line=$(awk -v ip="$ip" 'index($0, ip" ")==1{print;exit}' "$GEO")
  if [ -n "$line" ]; then
    set -- $line; ts=$1; shift; loc=$*
    if [ $((now-ts)) -lt 86400 ]; then echo "$loc"; return; fi
  fi
  loc=$(curl -sm 2 "http://ip-api.com/json/$ip?lang=zh-CN" 2>/dev/null \
        | jq -r 'if .status=="success" then (.country+" "+(.regionName//"-")+" "+(.city//"-")) else "-" end' 2>/dev/null)
  [ -z "$loc" ] && loc="-"
  printf '%s %s %s\n' "$ip" "$now" "$loc" >> "$GEO"
  echo "$loc"
}

TMP=$(mktemp)
{
  echo '['
  first=1
  for ip in $(printf '%s\n' "${!SEEN[@]}" | sort -u); do
    [ -z "$ip" ] && continue
    proto=$(printf '%s\n' ${PROTO[$ip]:-} | sort -u | tr '\n' ',' | sed 's/,$//')
    [ $first -eq 0 ] && echo ','
    jq -nc --arg ip "$ip" --arg loc "$(geoip "$ip")" --argjson dur "${DUR[$ip]:-0}" \
       --arg proto "$proto" --argjson up "${UP[$ip]:-0}" --argjson down "${DOWN[$ip]:-0}" \
       '{ip:$ip, location:$loc, duration:$dur, protocols:$proto, upload:$up, download:$down}'
    first=0
  done
  echo ']'
} > "$TMP"

total_up=0; total_down=0
for ip in "${!UP[@]}";   do total_up=$((total_up + ${UP[$ip]:-0})); done
for ip in "${!DOWN[@]}"; do total_down=$((total_down + ${DOWN[$ip]:-0})); done

DNSTMP=$(mktemp)
if [ -f /var/log/dnsmasq.log ] && [ -r /var/log/dnsmasq.log ]; then
  awk '/query\[/ { for(i=1;i<=NF;i++){ if($i ~ /^query\[/ && i+1<=NF && $(i+1) ~ /^[A-Za-z0-9_.-]+$/){ d[$(i+1)]++ } } }
       END { for(k in d) print d[k], k }' /var/log/dnsmasq.log 2>/dev/null \
    | sort -rn | head -25 > "$DNSTMP"
fi
DNSJ=$(mktemp)
if [ -s "$DNSTMP" ]; then
  while read -r c d; do jq -nc --arg d "$d" --argjson c "$c" '{domain:$d, count:$c}'; done < "$DNSTMP" > "$DNSJ"
fi

if [ -s "$DNSJ" ]; then
  jq -nc --argjson now "$now" --argjson up "$total_up" --argjson down "$total_down" \
     --slurpfile dns "$DNSJ" \
     '{now:$now, total_up:$up, total_down:$down, dns:$dns[0], devices:input}' < "$TMP" > "$OUT.tmp"
else
  jq -nc --argjson now "$now" --argjson up "$total_up" --argjson down "$total_down" \
     '{now:$now, total_up:$up, total_down:$down, devices:input}' < "$TMP" > "$OUT.tmp"
fi
mv "$OUT.tmp" "$OUT"
rm -f "$TMP" "$DNSTMP" "$DNSJ"
EOF
chmod +x /usr/local/bin/devmon.sh

echo "==> 2/3 更新 Web 服务超时并重启"
sed -i 's/timeout=30/timeout=60/' /usr/local/bin/devmon-web.py 2>/dev/null || true
systemctl restart devmon-web 2>/dev/null || systemctl daemon-reload && systemctl restart devmon-web

echo "==> 3/3 自检"
/usr/local/bin/devmon.sh
echo "  conntrack 条目: $(conntrack -L 2>/dev/null | grep -cE ' src=' || echo 0)"
echo "  ss 已建立连接: $(ss -tnH 2>/dev/null | grep -c ESTAB || echo 0)"
echo "  nft 表: $(nft list map inet netmon up >/dev/null 2>&1 && echo 存在 || echo '缺失(需重装)')"
echo "  采集错误日志: $(cat /var/lib/devmon/collect.log 2>/dev/null | grep -v '^$' || echo '无')"
echo "  采集结果:"
jq -r '.devices[]? | "    \(.ip)  \(.location)  \(.duration)s  [\(.protocols)]  ↑\(.upload) ↓\(.download)"' /var/lib/devmon/devices.json 2>/dev/null || echo "    (空)"
echo "  刷新页面 http://<服务器IP>:8080/?token=$(cat /etc/devmon.token 2>/dev/null || echo '?')"
echo
echo "  若仍为空，请执行排查:"
echo "    sudo conntrack -L | head        # 看有没有条目"
echo "    sudo ss -tnH | head             # 看有没有连接"
echo "    sudo bash -x /usr/local/bin/devmon.sh   # 跟踪采集过程"
