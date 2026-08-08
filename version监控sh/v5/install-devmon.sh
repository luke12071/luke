#!/bin/bash
# ============================================================
# DevMon — Ubuntu 24.04 轻量设备监控 + Web 管理页面  (v5)
# 功能: 在线设备/设备系统与型号(嗅探)/地点/时长/传输协议/端口服务(vless\ss等)/上下行流量/DNS
# 用法: sudo bash install-devmon.sh [端口]    默认端口 8080
# ============================================================
set -euo pipefail

PORT="${1:-8080}"

if [ "$(id -u)" -ne 0 ]; then
  echo "[!] 请用 root 执行: sudo bash install-devmon.sh ${PORT}"
  exit 1
fi

echo "==> 1/6 系统检查"
. /etc/os-release
echo "    系统: ${PRETTY_NAME}"
if [ "${VERSION_ID%%.*}" != "24" ]; then
  echo "    [!] 本脚本面向 Ubuntu 24.04，当前 ${VERSION_ID}，继续尝试"
fi
command -v nft >/dev/null || { echo "[!] 缺少 nftables，无法继续"; exit 1; }

echo "==> 2/6 安装依赖 (conntrack curl jq)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq conntrack curl jq

echo "==> 3/6 初始化 nftables 流量记账表 (netmon)"
mkdir -p /var/lib/devmon
nft -f /dev/stdin <<'NFT'
table inet netmon {
  map up   { type ipv4_addr : counter; }
  map down { type ipv4_addr : counter; }
  chain in  { type filter hook prerouting  priority 0; policy accept; ip saddr @up; }
  chain out { type filter hook postrouting priority 0; policy accept; ip daddr @down; }
}
NFT
cat > /etc/nftables.netmon <<'NFT'
table inet netmon {
  map up   { type ipv4_addr : counter; }
  map down { type ipv4_addr : counter; }
  chain in  { type filter hook prerouting  priority 0; policy accept; ip saddr @up; }
  chain out { type filter hook postrouting priority 0; policy accept; ip daddr @down; }
}
NFT
if ! grep -q 'nftables.netmon' /etc/crontab; then
  echo '@reboot root nft -f /etc/nftables.netmon' >> /etc/crontab
  echo "    已注册开机自启"
fi

echo "==> 4/6 安装采集器 /usr/local/bin/devmon.sh"
cat > /usr/local/bin/devmon.sh <<'EOF'
#!/bin/bash
# DevMon 采集器 v5 — 设备发现(conntrack/ss), 时长(conntrack[START]或first_seen), 上下行(nftables),
#   GeoIP定位, 端口->服务映射(vless\ss等), 设备名映射, 设备系统/型号/最近访问(sniffer), DNS统计
# 输出: /var/lib/devmon/devices.json   错误日志: /var/lib/devmon/collect.log
set -u
OUT=/var/lib/devmon/devices.json
GEO=/var/lib/devmon/geo.cache
STATE=/var/lib/devmon/state
SERVICES=/var/lib/devmon/services
NAMES=/var/lib/devmon/names
DEVINFO=/var/lib/devmon/deviceinfo
LOG=/var/lib/devmon/collect.log
now=$(date +%s)
[ -d /var/lib/devmon ] || mkdir -p /var/lib/devmon
[ -f "$GEO" ] || : > "$GEO"
[ -f "$SERVICES" ] || : > "$SERVICES"
[ -f "$NAMES" ] || : > "$NAMES"
: > "$LOG"

declare -A DUR PROTO PORTS UP DOWN SEEN FIRST_LAST SVCMAP NAMES_MAP DURF DEVOS DEVMOD DEVHOST

# --- 1. 设备发现 + 传输协议 + 本地端口 (conntrack 优先, ss 兜底) ---
while read -r proto ip port; do
  [ -z "${ip:-}" ] && continue
  PROTO[$ip]="${PROTO[$ip]:-} $proto"
  [ -n "${port:-}" ] && PORTS[$ip]="${PORTS[$ip]:-} $port"
done < <(conntrack -L 2>>"$LOG" | awk '
  $1 ~ /^(tcp|udp|sctp|gre)$/ && match($0,/src=[0-9.]+/) {
    ip=substr($0,RSTART+4,RLENGTH-4)
    port=""
    if (match($0,/ dport=[0-9]+/)) port=substr($0,RSTART+7,RLENGTH-7)
    print $1, ip, port
  }')

while read -r ip port; do
  [ -z "${ip:-}" ] && continue
  PROTO[$ip]="${PROTO[$ip]:-} tcp"
  [ -n "${port:-}" ] && PORTS[$ip]="${PORTS[$ip]:-} $port"
done < <(ss -tnH 2>/dev/null | awk '
  { split($4,a,":"); split($5,b,":")
    if (b[1] ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && b[1] != "0.0.0.0" && b[1] != "127.0.0.1") print b[1], a[2] }')

# --- 2. 连接时长: conntrack [START] 优先, 失败用 first_seen ---
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

# --- 4. 加载映射文件 (services: 端口 服务名; names: IP 设备名; # 开头为注释) ---
if [ -s "$SERVICES" ]; then
  while read -r port name; do
    case "$port" in ''|\#*) continue;; esac
    SVCMAP[$port]="$name"
  done < "$SERVICES"
fi
if [ -s "$NAMES" ]; then
  while read -r ip name; do
    case "$ip" in ''|\#*) continue;; esac
    NAMES_MAP[$ip]="$name"
  done < "$NAMES"
fi

# --- 5. first_seen 状态文件 (时长兜底, 设备消失10分钟重置) ---
if [ -f "$STATE" ]; then
  while read -r ip fs ls; do [ -n "${ip:-}" ] && FIRST_LAST[$ip]="$fs $ls"; done < "$STATE"
fi
for ip in "${!SEEN[@]}"; do
  if [ -n "${FIRST_LAST[$ip]:-}" ]; then
    fs=${FIRST_LAST[$ip]%% *}
    FIRST_LAST[$ip]="$fs $now"
  else
    FIRST_LAST[$ip]="$now $now"
  fi
done
for ip in "${!SEEN[@]}"; do
  d=${DUR[$ip]:-0}
  if [ "$d" -le 0 ] && [ -n "${FIRST_LAST[$ip]:-}" ]; then
    fs=${FIRST_LAST[$ip]%% *}
    d=$((now-fs)); [ "$d" -lt 0 ] && d=0
  fi
  DURF[$ip]=$d
done
: > "$STATE"
for ip in "${!FIRST_LAST[@]}"; do
  set -- ${FIRST_LAST[$ip]}
  if [ $((now-$2)) -lt 600 ] || [ -n "${SEEN[$ip]:-}" ]; then
    echo "$ip $1 $2" >> "$STATE"
  fi
done

internal() {
  case "$1" in
    10.*|192.168.*|127.*|169.254.*|100.6[4-9].*|100.7[0-9].*|100.8[0-9].*|100.9[0-9].*|100.1[0-1][0-9].*|100.12[0-7].*) return 0;;
    172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) return 0;;
  esac
  return 1
}

# --- 6. 设备系统/型号/最近访问 (deviceinfo TSV: src_ip<TAB>os<TAB>model<TAB>host<TAB>last_seen) ---
# 用 awk 转 '|' 分隔再 read, 避免 bash read 折叠连续制表符(空字段)导致错位
if [ -f "$DEVINFO" ]; then
  while IFS='|' read -r dip dos dmodel dhost dls; do
    case "$dip" in ''|\#*) continue;; esac
    DEVOS[$dip]="$dos"; DEVMOD[$dip]="$dmodel"; DEVHOST[$dip]="$dhost"
  done < <(awk -F '\t' '{print $1 "|" $2 "|" $3 "|" $4 "|" $5}' "$DEVINFO")
fi

geoip() {
  local ip=$1 line ts loc
  if internal "$ip"; then echo "内网"; return; fi
  line=$(awk -v ip="$ip" 'index($0, ip" ")==1{print;exit}' "$GEO")
  if [ -n "$line" ]; then
    set -- $line; ts=$2; shift 2; loc=$*
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
    svc=""
    for p in $(printf '%s\n' ${PORTS[$ip]:-} | sort -u); do
      [ -n "${SVCMAP[$p]:-}" ] && svc="$svc,${SVCMAP[$p]}"
    done
    svc=$(printf '%s' "$svc" | sed 's/^,//')
    internal_flag="false"; internal "$ip" && internal_flag="true"
    [ $first -eq 0 ] && echo ','
    jq -nc --arg ip "$ip" --arg name "${NAMES_MAP[$ip]:-}" --arg loc "$(geoip "$ip")" \
       --arg os "${DEVOS[$ip]:-}" --arg model "${DEVMOD[$ip]:-}" --arg visited "${DEVHOST[$ip]:-}" \
       --argjson dur "${DURF[$ip]:-0}" --arg proto "$proto" --arg svc "$svc" \
       --argjson up "${UP[$ip]:-0}" --argjson down "${DOWN[$ip]:-0}" \
       --argjson internal "$internal_flag" \
       '{ip:$ip, name:$name, location:$loc, os:$os, model:$model, visited:$visited, duration:$dur, protocols:$proto, services:$svc, upload:$up, download:$down, internal:$internal}'
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

echo "==> 4b/6 生成映射文件模板 (可编辑)"
if [ ! -f /var/lib/devmon/services ]; then
  cat > /var/lib/devmon/services <<'EOF'
# 端口 服务名  (每行一条, # 开头为注释)
443 vless
8388 ss
8443 trojan
EOF
fi
if [ ! -f /var/lib/devmon/names ]; then
  cat > /var/lib/devmon/names <<'EOF'
# IP 设备名  (每行一条, # 开头为注释)
# 203.0.113.5 我的手机
EOF
fi

echo "==> 4c/6 安装设备信息嗅探器 (/usr/local/bin/devmon-sniff.py)"
cat > /usr/local/bin/devmon-sniff.py <<'PYEOF'
#!/usr/bin/env python3
# DevMon 设备信息嗅探器 (v1)
# 监听入站 TCP 连接首个数据包，解析:
#   HTTP 明文  -> User-Agent 推断设备系统/型号 (iPhone/Android/Windows/macOS/Linux)
#   TLS 握手   -> SNI(访问域名) + JA3 指纹 (可对照 /var/lib/devmon/ja3db 推断系统)
# 输出: /var/lib/devmon/deviceinfo  (TSV: src_ip os model host last_seen)
# 限制: 加密隧道(vless/ss)内部流量无法解析, 属尽力而为; 需 root 或 CAP_NET_RAW
# 测试: DEVSNIFF_ANY=1 DEVSNIFF_IFACE=lo python3 devmon-sniff.py  (回环流量也抓)
import os, re, socket, struct, threading, time, hashlib

IFACE = os.environ.get("DEVSNIFF_IFACE", "")          # 留空 = 抓所有接口
ANY_FLAG = os.environ.get("DEVSNIFF_ANY", "") == "1"   # 测试用: 不跳过本机地址
DEVINFO = "/var/lib/devmon/deviceinfo"
JA3DB = "/var/lib/devmon/ja3db"
FLOW_TTL = 600          # 连接状态保留
DEVICE_TTL = 86400 * 3  # 设备信息保留 3 天

local_ips = set()
state = {}
devices = {}
lock = threading.Lock()
ja3_os = {}

def refresh_local():
    global local_ips
    local_ips = {"127.0.0.1", "::1"}
    try:
        out = os.popen("ip -o -4 addr show 2>/dev/null").read()
        for line in out.splitlines():
            p = line.split()
            if len(p) >= 4:
                local_ips.add(p[3].split("/")[0])
        out6 = os.popen("ip -o -6 addr show scope global 2>/dev/null").read()
        for line in out6.splitlines():
            p = line.split()
            if len(p) >= 4:
                local_ips.add(p[3].split("/")[0].lower())
    except Exception:
        pass

def load_ja3db():
    d = {}
    try:
        for line in open(JA3DB):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split(None, 1)
            if len(parts) == 2:
                d[parts[0].lower()] = parts[1].strip()
    except Exception:
        pass
    return d

def parse_ethernet(frame):
    if len(frame) < 14:
        return None, None
    return struct.unpack(">H", frame[12:14])[0], frame[14:]

def parse_ipv4(pkt):
    if len(pkt) < 20:
        return None
    ihl = (pkt[0] & 0x0F) * 4
    src = socket.inet_ntop(socket.AF_INET, pkt[12:16])
    dst = socket.inet_ntop(socket.AF_INET, pkt[16:20])
    return pkt[9], src, dst, pkt[ihl:]

def parse_ipv6(pkt):
    if len(pkt) < 40:
        return None
    src = socket.inet_ntop(socket.AF_INET6, pkt[8:24])
    dst = socket.inet_ntop(socket.AF_INET6, pkt[24:40])
    return pkt[6], src, dst, pkt[40:]

def parse_tcp(tcp):
    if len(tcp) < 20:
        return None
    sport, dport = struct.unpack(">HH", tcp[0:4])
    doff = (tcp[12] >> 4) * 4
    return sport, dport, tcp[doff:]

def parse_ua(ua):
    r = {"os": "", "model": ""}
    l = ua.lower()
    if "iphone" in l:
        r["os"], r["model"] = "iOS", "iPhone"
        m = re.search(r"iphone os (\d+)", l)
        if m:
            r["os"] = "iOS " + m.group(1)
    elif "ipad" in l:
        r["os"], r["model"] = "iPadOS", "iPad"
    elif "android" in l:
        r["os"] = "Android"
        m = re.search(r"android (\d+)", l)
        if m:
            r["os"] = "Android " + m.group(1)
        m = re.search(r";\s*([a-z0-9_\- ]+?)\s+build", ua, re.I)
        if m:
            r["model"] = re.sub(r"\s+", " ", m.group(1)).strip()
    elif "windows" in l:
        r["os"] = "Windows"
        m = re.search(r"windows nt (\d+\.\d+)", l)
        if m:
            r["os"] = "Windows " + {"5.1": "XP", "6.0": "Vista", "6.1": "7",
                                    "6.2": "8", "6.3": "8.1", "10.0": "10/11"}.get(m.group(1), "")
            r["os"] = r["os"].rstrip()
    elif "macintosh" in l or "mac os x" in l:
        r["os"] = "macOS"
        m = re.search(r"mac os x (\d+)[_\.](\d+)", l)
        if m:
            r["os"] = "macOS " + m.group(1) + "." + m.group(2)
    elif "curl/" in l:
        r["os"] = "Linux (curl)"
    elif "linux" in l:
        r["os"] = "Linux"
    return r

def parse_http(data):
    try:
        text = data.decode("utf-8", "ignore")
    except Exception:
        text = data.decode("latin1", "ignore")
    info = {}
    lines = text.split("\r\n")
    if lines and lines[0]:
        parts = lines[0].split(" ", 2)
        if parts and parts[0].upper() == "CONNECT" and len(parts) > 1:
            info["host"] = parts[1].split(":")[0]
    for line in lines[1:]:
        if line == "":
            break
        if ":" in line:
            k, v = line.split(":", 1)
            k = k.strip().lower()
            if k == "user-agent":
                info.update(parse_ua(v.strip()))
            elif k == "host" and not info.get("host"):
                info["host"] = v.strip().split(":")[0]
    return info

def is_grease(v):
    # RFC 8701: values 0x?a?a, e.g. 0x0a0a..0xfafa. JA3 spec ignores them.
    return v > 0x0A0A and (v & 0x0F0F) == 0x0A0A

def parse_clienthello(data):
    if len(data) < 5 or data[0] != 0x16:
        return {}
    body = data[5:]
    if len(body) < 4 or body[0] != 0x01:
        return {}
    ch = body[4:]
    if len(ch) < 36:
        return {}
    version = struct.unpack(">H", ch[0:2])[0]
    pos = 35 + ch[34]
    if pos + 2 > len(ch):
        return {}
    clen = struct.unpack(">H", ch[pos:pos + 2])[0]; pos += 2
    if pos + clen > len(ch):
        return {}
    ciphers = [ch[pos + 2 * i: pos + 2 * i + 2].hex() for i in range(clen // 2)
               if not is_grease(struct.unpack(">H", ch[pos + 2 * i: pos + 2 * i + 2])[0])]
    pos += clen
    if pos >= len(ch):
        return {}
    complen = ch[pos]; pos += 1 + complen
    if pos + 2 > len(ch):
        return {}
    ext_total = struct.unpack(">H", ch[pos:pos + 2])[0]; pos += 2
    exts, order = {}, []
    end = min(pos + ext_total, len(ch))
    while pos + 4 <= end:
        et = struct.unpack(">H", ch[pos:pos + 2])[0]
        elen = struct.unpack(">H", ch[pos + 2:pos + 4])[0]
        pos += 4
        ed = ch[pos:pos + elen]
        pos += elen
        if is_grease(et):
            continue
        exts[et] = ed
        order.append(et)
    sni = ""
    if 0 in exts:
        d = exts[0]
        if len(d) > 5:
            try:
                nl = struct.unpack(">H", d[3:5])[0]
                sni = d[5:5 + nl].decode("utf-8", "ignore")
            except Exception:
                pass
    groups = []
    if 10 in exts:
        d = exts[10]
        if len(d) >= 2:
            glen = struct.unpack(">H", d[0:2])[0]
            groups = [d[2 + 2 * i: 2 + 2 * i + 2].hex() for i in range(min(glen // 2, (len(d) - 2) // 2))
                      if not is_grease(struct.unpack(">H", d[2 + 2 * i: 2 + 2 * i + 2])[0])]
    ec = []
    if 11 in exts:
        d = exts[11]
        ec = [str(b) for b in d[1:]]
    cstr = ",".join(ciphers)
    estr = ",".join(str(e) for e in order)
    gstr = ",".join(groups)
    ecstr = ",".join(ec)
    ja3 = hashlib.md5("{},{},{},{},{}".format(version, cstr, estr, gstr, ecstr).encode()).hexdigest()
    return {"ja3": ja3, "host": sni, "os": ja3_os.get(ja3, "")}

def handle(src, data, now):
    info = {}
    if data[:1] == b"\x16":
        info = parse_clienthello(data)
    else:
        head = data[:12].upper()
        if head.startswith((b"GET ", b"POST", b"HEAD", b"PUT ", b"CONNECT", b"OPTI", b"DELE")):
            info = parse_http(data)
    if not info:
        return
    with lock:
        old = devices.get(src, {})
        devices[src] = {"os": info.get("os") or old.get("os", ""),
                        "model": info.get("model") or old.get("model", ""),
                        "host": info.get("host") or old.get("host", ""),
                        "last": int(now)}

def run():
    global ja3_os
    ja3_os = load_ja3db()
    refresh_local()
    sock = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.ntohs(0x0003))
    if IFACE:
        sock.bind((IFACE, 0))
    while True:
        try:
            frame = sock.recv(65535)
        except Exception:
            time.sleep(0.1)
            continue
        et, pkt = parse_ethernet(frame)
        if et == 0x0800:
            r = parse_ipv4(pkt)
        elif et == 0x86DD:
            r = parse_ipv6(pkt)
        else:
            continue
        if not r:
            continue
        proto, src, dst, payload = r
        if proto != 6:
            continue
        if not ANY_FLAG and src in local_ips:
            continue
        t = parse_tcp(payload)
        if not t:
            continue
        sport, dport, data = t
        if not data:
            continue
        key = (src, sport, dport)
        now = time.time()
        if key in state and now - state[key][0] < FLOW_TTL:
            continue
        state[key] = (now, len(data))
        if len(state) > 20000:
            for k in list(state):
                if now - state[k][0] > FLOW_TTL:
                    state.pop(k, None)
        handle(src, data, now)

def write_once():
    now = time.time()
    with lock:
        devs = dict(devices)
    for ip in list(devs):
        if now - devs[ip]["last"] > DEVICE_TTL:
            with lock:
                devices.pop(ip, None)
            devs.pop(ip, None)
    if not devs:
        return
    tmp = DEVINFO + ".tmp"
    try:
        with open(tmp, "w") as f:
            for ip in sorted(devs, key=lambda x: -devs[x]["last"]):
                d = devs[ip]
                f.write("{}\t{}\t{}\t{}\t{}\n".format(ip, d["os"], d["model"], d["host"], d["last"]))
        os.replace(tmp, DEVINFO)
    except Exception:
        pass

def writer():
    while True:
        time.sleep(5)
        write_once()

if __name__ == "__main__":
    threading.Thread(target=writer, daemon=True).start()
    print("devmon-sniff 运行中 (接口={}, 输出={})".format(IFACE or "所有", DEVINFO), flush=True)
    run()
PYEOF
chmod +x /usr/local/bin/devmon-sniff.py

if [ ! -f /var/lib/devmon/ja3db ]; then
  cat > /var/lib/devmon/ja3db <<'EOF'
# JA3 TLS 指纹 -> 客户端/系统 映射库   (每行: <32位ja3> 说明)
# 浏览器指纹随版本频繁变化; 查询真实指纹: https://ja3er.com  (提交后回填这里)
# 常见库/工具指纹(较稳定):
13d6c21643a4d76c419bc34706a949d0 Linux curl (OpenSSL)
eb22cb93e4e72e23d8050e20f60ef68f Python requests (urllib3)
EOF
fi

cat > /etc/systemd/system/devmon-sniff.service <<EOF
[Unit]
Description=DevMon Device Info Sniffer
After=network.target

[Service]
ExecStart=/usr/local/bin/devmon-sniff.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable devmon-sniff >/dev/null 2>&1
systemctl restart devmon-sniff
echo "    嗅探服务已启动"

echo "==> 5/6 安装 Web 管理页面 + systemd 服务"
cat > /usr/local/bin/devmon-web.py <<'PYEOF'
#!/usr/bin/env python3
import hashlib, hmac, os, secrets, subprocess, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

DATA = "/var/lib/devmon/devices.json"
COLL = "/usr/local/bin/devmon.sh"
TOKEN_FILE = "/etc/devmon.token"
AUTH_FILE = "/etc/devmon.auth"
REFRESH = 5
SESSION_TTL = 7 * 86400
SESSIONS = {}

INDEX = """<!doctype html>
<html lang="zh">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>DevMon 设备监控</title>
<style>
*{box-sizing:border-box}
body{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;background:#0f1420;color:#e6e6e6;margin:0;padding:24px}
h1{font-size:20px;margin:0 0 6px}
.top{display:flex;align-items:center;justify-content:space-between}
.top a{color:#8a93a6;font-size:12px;text-decoration:none}
.top a:hover{color:#c9d1e5}
.meta{color:#8a93a6;font-size:12px;margin-bottom:18px}
.cards{display:flex;gap:12px;margin-bottom:20px;flex-wrap:wrap}
.card{background:#171e2e;border:1px solid #25304a;border-radius:8px;padding:12px 18px;min-width:140px}
.card b{font-size:22px;display:block;margin-top:4px}
.card span{font-size:12px;color:#8a93a6}
h2{font-size:15px;margin:24px 0 10px;color:#c9d1e5}
.tabs{display:flex;gap:8px;margin-bottom:12px}
.tabs button{background:#171e2e;border:1px solid #25304a;color:#8a93a6;border-radius:6px;padding:6px 16px;cursor:pointer;font-size:13px}
.tabs button.on{background:#2b3a61;border-color:#3b4e85;color:#fff}
table{width:100%;border-collapse:collapse;background:#171e2e;border:1px solid #25304a;border-radius:8px;overflow-x:auto;display:block}
th,td{padding:8px 12px;text-align:left;border-bottom:1px solid #232e47;font-size:13px;white-space:nowrap}
th{background:#1d2740;color:#8a93a6;font-weight:600}
tbody tr:hover{background:#1c2640}
.badge{background:#2b3a61;border-radius:4px;padding:2px 6px;font-size:12px;margin-right:4px}
.badge.svc{background:#3a3a2b;border:1px solid #5a5231;color:#e8d68a}
.sub{color:#6b7490;font-size:11px}
.empty{color:#8a93a6;text-align:center;padding:32px}
code{color:#7fd0ff}
</style>
</head>
<body>
<div class="top"><h1>DevMon 设备监控</h1><a href="/logout">退出登录</a></div>
<div class="meta">在线设备 <span id="cnt">-</span> 个 · 刷新于 <span id="ts">-</span></div>
<div class="cards">
 <div class="card"><span>在线设备</span><b id="dev">-</b></div>
 <div class="card"><span>总上行</span><b id="up">-</b></div>
 <div class="card"><span>总下行</span><b id="down">-</b></div>
</div>
<h2>在线设备</h2>
<div class="tabs">
 <button id="t-all" class="on" onclick="filt('all')">全部</button>
 <button id="t-in" onclick="filt('in')">内网</button>
 <button id="t-out" onclick="filt('out')">外网</button>
</div>
<table><thead><tr><th>设备</th><th>设备系统</th><th>最近访问</th><th>地点</th><th>连接时长</th><th>传输协议</th><th>服务</th><th>上行</th><th>下行</th></tr></thead>
<tbody id="rows"><tr><td class="empty" colspan="9">加载中…</td></tr></tbody></table>
<h2>DNS 请求 TOP</h2>
<table><thead><tr><th>域名</th><th>请求数</th></tr></thead>
<tbody id="dns"><tr><td class="empty" colspan="2">未启用 DNS 日志 (enable-dnslog.sh 可开)</td></tr></tbody></table>
<script>
const hum=n=>{if(n<1024)return n+' B';const u=['K','M','G','T','P'];let i=0;while(n>=1024&&i<4){n/=1024;i++}return n.toFixed(1)+' '+u[i]+'B'};
const dur=s=>{if(!s)return '-';if(s<60)return s+'s';if(s<3600)return Math.floor(s/60)+'m'+Math.floor(s%60)+'s';return Math.floor(s/3600)+'h'+Math.floor(s%3600/60)+'m'};
const esc=s=>String(s??'').replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
const api='/api/devices';
let DATA=[],cur='all';
function badges(list,cls){return list.filter(Boolean).map(p=>`<span class="badge ${cls||''}">${esc(p)}</span>`).join('')}
function render(){
 const ds=DATA.filter(x=>cur==='all'||(cur==='in'&&x.internal)||(cur==='out'&&!x.internal));
 document.getElementById('dev').textContent=ds.length;
 document.getElementById('cnt').textContent=ds.length;
 document.getElementById('rows').innerHTML=ds.map(x=>`<tr>
  <td><b>${esc(x.name||x.ip)}</b>${x.name?'<div class="sub">'+esc(x.ip)+'</div>':''}</td>
  <td>${[x.os,x.model].filter(Boolean).join(' ')||'-'}</td>
  <td>${x.visited?'<code>'+esc(x.visited)+'</code>':'-'}</td>
  <td>${esc(x.location||'-')}</td>
  <td>${dur(x.duration)}</td>
  <td>${badges((x.protocols||'').split(','))}</td>
  <td>${badges((x.services||'').split(','),'svc')||'-'}</td>
  <td>${hum(x.upload||0)}</td>
  <td>${hum(x.download||0)}</td></tr>`).join('')||'<tr><td class="empty" colspan="9">暂无在线设备</td></tr>';
}
function filt(k){cur=k;document.querySelectorAll('.tabs button').forEach(b=>b.classList.toggle('on',b.id==='t-'+k));render()}
async function load(){
 try{
  const r=await fetch(api);
  if(r.status===401){location.href='/login';return}
  const d=await r.json();
  DATA=d.devices||[];
  document.getElementById('up').textContent=hum(d.total_up||0);
  document.getElementById('down').textContent=hum(d.total_down||0);
  document.getElementById('ts').textContent=new Date().toLocaleString('zh-CN');
  render();
  const dl=d.dns||[];
  document.getElementById('dns').innerHTML=dl.length?dl.map(x=>`<tr><td><code>${esc(x.domain)}</code></td><td>${x.count}</td></tr>`).join(''):'<tr><td class="empty" colspan="2">暂无数据</td></tr>';
 }catch(e){document.getElementById('ts').textContent='加载失败: '+e}
}
setInterval(load,5000);load();
</script>
</body>
</html>"""

LOGIN = """<!doctype html>
<html lang="zh">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>登录 - DevMon</title>
<style>
*{box-sizing:border-box}
body{font-family:ui-monospace,Menlo,Consolas,monospace;background:#0f1420;color:#e6e6e6;display:flex;align-items:center;justify-content:center;min-height:100vh;margin:0}
.card{background:#171e2e;border:1px solid #25304a;border-radius:10px;padding:28px 32px;width:300px}
.card h1{font-size:18px;margin:0 0 18px;text-align:center;color:#c9d1e5}
input{width:100%;background:#0f1420;border:1px solid #25304a;color:#e6e6e6;border-radius:6px;padding:10px 12px;margin-bottom:12px;font-size:14px}
button{width:100%;background:#2b3a61;border:1px solid #3b4e85;color:#fff;border-radius:6px;padding:10px;font-size:14px;cursor:pointer;margin-top:4px}
button:hover{background:#35508f}
.err{color:#ff7b72;font-size:13px;text-align:center;margin-top:10px}
</style>
</head>
<body><div class="card">
<h1>DevMon</h1>
<form method="post" action="/login">
<input type="text" name="username" placeholder="用户名" autocomplete="username" required>
<input type="password" name="password" placeholder="密码" autocomplete="current-password" required>
<button>登录</button>
</form>__ERR__
</div></body></html>"""

def load_auth():
    d = {}
    try:
        for line in open(AUTH_FILE):
            line = line.strip()
            if ":" in line:
                k, v = line.split(":", 1)
                d[k] = v
    except Exception:
        pass
    return d

def verify(user, pwd):
    a = load_auth()
    if not a:
        return False
    try:
        salt = bytes.fromhex(a.get("salt", ""))
        it = int(a.get("iterations", "200000"))
        h = hashlib.pbkdf2_hmac("sha256", pwd.encode(), salt, it).hex()
    except Exception:
        return False
    return user == a.get("username", "") and hmac.compare_digest(h, a.get("hash", ""))

class H(BaseHTTPRequestHandler):
    def authed(self):
        for part in self.headers.get("Cookie", "").split(";"):
            part = part.strip()
            if part.startswith("devmon_session="):
                tok = part.split("=", 1)[1]
                if tok in SESSIONS and SESSIONS[tok] > time.time():
                    SESSIONS[tok] = time.time() + SESSION_TTL
                    return True
                SESSIONS.pop(tok, None)
        tok = ""
        try:
            tok = open(TOKEN_FILE).read().strip()
        except Exception:
            pass
        if tok:
            q = parse_qs(urlparse(self.path).query)
            if q.get("token") == [tok]:
                return True
            if self.headers.get("X-Token") == tok:
                return True
        return False

    def _fresh(self):
        try:
            if not os.path.exists(DATA) or (time.time() - os.path.getmtime(DATA)) > REFRESH:
                subprocess.run([COLL], capture_output=True, timeout=60)
        except Exception:
            pass

    def _send(self, code, ctype, body, headers=None, loc=None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        if loc:
            self.send_header("Location", loc)
        for k, v in (headers or []):
            self.send_header(k, v)
        self.end_headers()
        try:
            self.wfile.write(body)
        except Exception:
            pass

    def do_GET(self):
        p = urlparse(self.path).path
        if p == "/login":
            if self.authed():
                return self._send(302, "text/plain; charset=utf-8", b"ok", loc="/")
            return self._send(200, "text/html; charset=utf-8", LOGIN.replace("__ERR__", "").encode())
        if p == "/logout":
            for part in self.headers.get("Cookie", "").split(";"):
                part = part.strip()
                if part.startswith("devmon_session="):
                    SESSIONS.pop(part.split("=", 1)[1], None)
            return self._send(200, "text/html; charset=utf-8",
                "<meta http-equiv='refresh' content='0;url=/login'><body>已退出</body>".encode(),
                [("Set-Cookie", "devmon_session=; Max-Age=0; Path=/; HttpOnly; SameSite=Lax")])
        if not self.authed():
            return self._send(302, "text/plain; charset=utf-8", b"login required", loc="/login")
        if p == "/api/devices":
            self._fresh()
            body = b'{"now":0,"total_up":0,"total_down":0,"devices":[]}'
            if os.path.exists(DATA):
                try:
                    body = open(DATA, "rb").read()
                except Exception:
                    pass
            self._send(200, "application/json; charset=utf-8", body)
        elif p == "/":
            self._send(200, "text/html; charset=utf-8", INDEX.encode())
        else:
            self._send(404, "text/plain; charset=utf-8", b"not found")

    def do_POST(self):
        p = urlparse(self.path).path
        if p != "/login":
            self._send(404, "text/plain; charset=utf-8", b"not found")
            return
        u = pw = ""
        try:
            n = int(self.headers.get("Content-Length", "0"))
            f = parse_qs(self.rfile.read(n).decode())
            u = (f.get("username") or [""])[0]
            pw = (f.get("password") or [""])[0]
        except Exception:
            pass
        if verify(u, pw):
            tok = secrets.token_hex(16)
            SESSIONS[tok] = time.time() + SESSION_TTL
            return self._send(302, "text/plain; charset=utf-8", b"ok",
                [("Set-Cookie", f"devmon_session={tok}; Max-Age={SESSION_TTL}; Path=/; HttpOnly; SameSite=Lax")],
                loc="/")
        self._send(200, "text/html; charset=utf-8", LOGIN.replace("__ERR__", '<div class="err">用户名或密码错误</div>').encode())

    def log_message(self, fmt, *args):
        pass

if __name__ == "__main__":
    import sys
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
    print(f"DevMon listening on 0.0.0.0:{port}")
    ThreadingHTTPServer(("0.0.0.0", port), H).serve_forever()
PYEOF
chmod +x /usr/local/bin/devmon-web.py

cat > /usr/local/bin/enable-dnslog.sh <<'DSH'
#!/bin/bash
# DevMon: 记录本机自身 DNS 请求 -> /var/log/dnsmasq.log (页面自动展示)
# systemd-resolved(127.0.0.53) -> dnsmasq(127.0.0.1:53, 日志) -> 上游公共DNS
# 回滚: sudo bash disable-dnslog.sh
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "需 root: sudo bash enable-dnslog.sh"; exit 1; }

echo "==> 1/4 安装 dnsmasq"
export DEBIAN_FRONTEND=noninteractive
apt-get install -y -qq dnsmasq

echo "==> 2/4 写入 dnsmasq 配置"
cp /etc/systemd/resolved.conf /etc/systemd/resolved.conf.bak.devmon 2>/dev/null || true
mkdir -p /etc/dnsmasq.d
cat > /etc/dnsmasq.d/devmon-local.conf <<'EOF'
interface=lo
bind-interfaces
listen-address=127.0.0.1
port=53
no-hosts
no-resolv
log-queries
log-facility=/var/log/dnsmasq.log
server=223.5.5.5
server=119.29.29.29
server=1.1.1.1
server=8.8.8.8
EOF
systemctl restart dnsmasq

echo "==> 3/4 systemd-resolved 上游指向 dnsmasq"
mkdir -p /etc/systemd/resolved.conf.d
cat > /etc/systemd/resolved.conf.d/devmon.conf <<'EOF'
[Resolve]
DNS=127.0.0.1
EOF
systemctl restart systemd-resolved

echo "==> 4/4 完成"
echo "  本机 DNS 请求已记录到 /var/log/dnsmasq.log，页面自动展示 TOP"
echo "  验证: nslookup example.com && tail -3 /var/log/dnsmasq.log"
echo "  回滚: sudo bash disable-dnslog.sh"
DSH
chmod +x /usr/local/bin/enable-dnslog.sh

cat > /usr/local/bin/disable-dnslog.sh <<'DSH'
#!/bin/bash
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "需 root: sudo bash disable-dnslog.sh"; exit 1; }
rm -f /etc/dnsmasq.d/devmon-local.conf
rm -f /etc/systemd/resolved.conf.d/devmon.conf
systemctl restart systemd-resolved
systemctl restart dnsmasq 2>/dev/null || systemctl stop dnsmasq
[ -f /etc/systemd/resolved.conf.bak.devmon ] && cp /etc/systemd/resolved.conf.bak.devmon /etc/systemd/resolved.conf
echo "已回滚 DNS 配置 (本机恢复 systemd-resolved 默认解析)"
DSH
chmod +x /usr/local/bin/disable-dnslog.sh

cat > /usr/local/bin/devmon-passwd.sh <<'PWD'
#!/bin/bash
# DevMon: 设置/修改 Web 登录账号密码 (PBKDF2-SHA256 加盐)
# 用法: sudo bash devmon-passwd.sh [用户名]   默认 admin
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "需 root: sudo bash devmon-passwd.sh"; exit 1; }
USER="${1:-admin}"
read -s -r -p "输入新密码: " P1; echo
read -s -r -p "再次输入密码: " P2; echo
[ "$P1" = "$P2" ] || { echo "[!] 两次输入不一致"; exit 1; }
SALT=$(python3 -c 'import secrets; print(secrets.token_hex(16))')
HASH=$(python3 -c 'import hashlib,sys; print(hashlib.pbkdf2_hmac("sha256", sys.argv[1].encode(), bytes.fromhex(sys.argv[2]), 200000).hex())' "$P1" "$SALT")
printf 'username:%s\nsalt:%s\niterations:200000\nhash:%s\n' "$USER" "$SALT" "$HASH" > /etc/devmon.auth
chmod 600 /etc/devmon.auth
echo "已设置登录账号: $USER"
PWD
chmod +x /usr/local/bin/devmon-passwd.sh

cat > /etc/systemd/system/devmon-web.service <<EOF
[Unit]
Description=DevMon Web Dashboard
After=network.target

[Service]
ExecStart=/usr/local/bin/devmon-web.py ${PORT}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

echo "==> 6/6 启动并初始化"
TOKEN=$(head -c9 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c12)
[ -s /etc/devmon.token ] || echo "$TOKEN" > /etc/devmon.token
if [ ! -s /etc/devmon.auth ]; then
  ADMIN_PW=$(head -c12 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c12)
  SALT=$(python3 -c 'import secrets; print(secrets.token_hex(16))')
  HASH=$(python3 -c 'import hashlib,sys; print(hashlib.pbkdf2_hmac("sha256", sys.argv[1].encode(), bytes.fromhex(sys.argv[2]), 200000).hex())' "$ADMIN_PW" "$SALT")
  printf 'username:admin\nsalt:%s\niterations:200000\nhash:%s\n' "$SALT" "$HASH" > /etc/devmon.auth
  chmod 600 /etc/devmon.auth
else
  ADMIN_PW="(沿用已有账号配置 /etc/devmon.auth)"
fi
/usr/local/bin/devmon.sh
systemctl daemon-reload
systemctl enable devmon-web >/dev/null 2>&1
systemctl restart devmon-web

IP=$(hostname -I | awk '{print $1}')
PORT_MSG=""
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow "${PORT}"/tcp >/dev/null 2>&1 && PORT_MSG="（ufw 已放行）"
fi

echo
echo "============================================================"
echo " 安装完成！"
echo " 管理页面: http://${IP}:${PORT}/    (需要登录)"
echo " 登录账号: admin"
echo " 登录密码: ${ADMIN_PW}"
echo " 修改密码: sudo bash devmon-passwd.sh"
echo " API旧链接: http://${IP}:${PORT}/?token=$(cat /etc/devmon.token)"
echo " 云端安全组请放行 TCP ${PORT} ${PORT_MSG}"
echo " 数据文件: /var/lib/devmon/devices.json"
echo " 错误日志: /var/lib/devmon/collect.log"
echo " 手动刷新: sudo /usr/local/bin/devmon.sh"
echo " 设备嗅探: /var/lib/devmon/deviceinfo (系统/型号/最近访问, 含JA3指纹库 ja3db)"
echo "============================================================"
echo " [可选1] 本机自身 DNS 请求统计: sudo bash enable-dnslog.sh"
echo " [可选2] 给设备命名/标注代理服务:"
echo "   sudo nano /var/lib/devmon/names      # IP 设备名"
echo "   sudo nano /var/lib/devmon/services   # 端口 服务名(如 8388 ss)"
echo "   改完刷新页面即可生效"
