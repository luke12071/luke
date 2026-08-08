#!/bin/bash
# ============================================================
# DevMon — Ubuntu 24.04 轻量设备监控 + Web 管理页面
# 功能: 在线设备 / 地点(GeoIP) / 连接时长 / 协议 / 上下行流量 / DNS请求(可选)
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
# DevMon 采集器: conntrack(连接/时长/协议) + nftables(上下行) + GeoIP(地点) + DNS(可选)
# 输出: /var/lib/devmon/devices.json
set -u
OUT=/var/lib/devmon/devices.json
GEO=/var/lib/devmon/geo.cache
now=$(date +%s)
[ -d /var/lib/devmon ] || mkdir -p /var/lib/devmon
[ -f "$GEO" ] || : > "$GEO"

declare -A DUR PROTO UP DOWN SEEN

while read -r st proto ip; do
  [ -z "${ip:-}" ] && continue
  d=$((now-st)); [ "$d" -lt 0 ] && d=0
  [ "${DUR[$ip]:-0}" -lt "$d" ] && DUR[$ip]=$d
  PROTO[$ip]="${PROTO[$ip]:-} $proto"
done < <(conntrack -L -o timestamp 2>/dev/null | awk '
  /^\[START\]|^\[STOP\]/ { if (buf) print $2, buf; buf=""; next }
  $1 ~ /^(tcp|udp|sctp|gre)$/ && match($0,/src=[0-9.]+/) { buf=$1 " " substr($0,RSTART+4,RLENGTH-4) }')

if nft list map inet netmon up >/dev/null 2>&1; then
  while read -r ip _ _ b; do UP[$ip]=$b; done < <(nft list map inet netmon up   | grep -oE '[0-9.]+ counter packets [0-9]+ bytes [0-9]+')
  while read -r ip _ _ b; do DOWN[$ip]=$b; done < <(nft list map inet netmon down | grep -oE '[0-9.]+ counter packets [0-9]+ bytes [0-9]+')
fi

geoip() {
  local ip=$1 line ts loc
  line=$(awk -v ip="$ip" 'index($0, ip" ")==1{print;exit}' "$GEO")
  if [ -n "$line" ]; then
    set -- $line; ts=$1; shift; loc=$*
    if [ $((now-ts)) -lt 86400 ]; then echo "$loc"; return; fi
  fi
  loc=$(curl -sm 3 "http://ip-api.com/json/$ip?lang=zh-CN" 2>/dev/null \
        | jq -r 'if .status=="success" then (.country+" "+(.regionName//"-")+" "+(.city//"-")) else "-" end' 2>/dev/null)
  [ -z "$loc" ] && loc="-"
  printf '%s %s %s\n' "$ip" "$now" "$loc" >> "$GEO"
  echo "$loc"
}

for ip in "${!DUR[@]}" "${!UP[@]}" "${!DOWN[@]}"; do SEEN[$ip]=1; done

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

echo "==> 5/6 安装 Web 管理页面 + systemd 服务"
cat > /usr/local/bin/devmon-web.py <<'PYEOF'
#!/usr/bin/env python3
import os, subprocess, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

DATA = "/var/lib/devmon/devices.json"
COLL = "/usr/local/bin/devmon.sh"
TOKEN_FILE = "/etc/devmon.token"
REFRESH = 5

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
.meta{color:#8a93a6;font-size:12px;margin-bottom:18px}
.cards{display:flex;gap:12px;margin-bottom:24px;flex-wrap:wrap}
.card{background:#171e2e;border:1px solid #25304a;border-radius:8px;padding:12px 18px;min-width:140px}
.card b{font-size:22px;display:block;margin-top:4px}
.card span{font-size:12px;color:#8a93a6}
h2{font-size:15px;margin:24px 0 10px;color:#c9d1e5}
table{width:100%;border-collapse:collapse;background:#171e2e;border:1px solid #25304a;border-radius:8px;overflow:hidden}
th,td{padding:8px 12px;text-align:left;border-bottom:1px solid #232e47;font-size:13px;white-space:nowrap}
th{background:#1d2740;color:#8a93a6;font-weight:600}
tbody tr:hover{background:#1c2640}
.badge{background:#2b3a61;border-radius:4px;padding:2px 6px;font-size:12px;margin-right:4px}
.empty{color:#8a93a6;text-align:center;padding:32px}
code{color:#7fd0ff}
</style>
</head>
<body>
<h1>DevMon 设备监控</h1>
<div class="meta">在线设备 <span id="cnt">-</span> 个 · 刷新于 <span id="ts">-</span></div>
<div class="cards">
 <div class="card"><span>在线设备</span><b id="dev">-</b></div>
 <div class="card"><span>总上行</span><b id="up">-</b></div>
 <div class="card"><span>总下行</span><b id="down">-</b></div>
</div>
<h2>在线设备</h2>
<table><thead><tr><th>设备 IP</th><th>地点</th><th>连接时长</th><th>协议</th><th>上行</th><th>下行</th></tr></thead>
<tbody id="rows"><tr><td class="empty" colspan="6">加载中…</td></tr></tbody></table>
<h2>DNS 请求 TOP</h2>
<table><thead><tr><th>域名</th><th>请求数</th></tr></thead>
<tbody id="dns"><tr><td class="empty" colspan="2">未启用 DNS 日志</td></tr></tbody></table>
<script>
const hum=n=>{if(n<1024)return n+' B';const u=['K','M','G','T','P'];let i=0;while(n>=1024&&i<4){n/=1024;i++}return n.toFixed(1)+' '+u[i]+'B'};
const dur=s=>{if(!s)return '-';if(s<60)return s+'s';if(s<3600)return Math.floor(s/60)+'m'+Math.floor(s%60)+'s';return Math.floor(s/3600)+'h'+Math.floor(s%3600/60)+'m'};
const esc=s=>String(s??'').replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
const tok=new URLSearchParams(location.search).get('token')||'';
const api='/api/devices'+(tok?'?token='+tok:'');
async function load(){
 try{
  const d=await (await fetch(api)).json();
  const ds=d.devices||[];
  document.getElementById('dev').textContent=ds.length;
  document.getElementById('up').textContent=hum(d.total_up||0);
  document.getElementById('down').textContent=hum(d.total_down||0);
  document.getElementById('cnt').textContent=ds.length;
  document.getElementById('ts').textContent=new Date().toLocaleString('zh-CN');
  document.getElementById('rows').innerHTML=ds.map(x=>`<tr>
   <td>${esc(x.ip)}</td>
   <td>${esc(x.location||'-')}</td>
   <td>${dur(x.duration)}</td>
   <td>${(x.protocols||'').split(',').filter(Boolean).map(p=>`<span class="badge">${esc(p)}</span>`).join('')}</td>
   <td>${hum(x.upload||0)}</td>
   <td>${hum(x.download||0)}</td></tr>`).join('')||'<tr><td class="empty" colspan="6">暂无在线设备</td></tr>';
  const dl=d.dns||[];
  document.getElementById('dns').innerHTML=dl.length?dl.map(x=>`<tr><td><code>${esc(x.domain)}</code></td><td>${x.count}</td></tr>`).join(''):'<tr><td class="empty" colspan="2">暂无数据</td></tr>';
 }catch(e){document.getElementById('ts').textContent='加载失败: '+e}
}
setInterval(load,5000);load();
</script>
</body>
</html>"""

class H(BaseHTTPRequestHandler):
    def authorized(self):
        tok = ""
        try:
            tok = open(TOKEN_FILE).read().strip()
        except Exception:
            pass
        if not tok:
            return True
        q = urlparse(self.path).query
        p = {}
        for x in q.split("&"):
            if "=" in x:
                k, v = x.split("=", 1)
                p[k] = v
        if p.get("token") == tok:
            return True
        if self.headers.get("X-Token") == tok:
            return True
        return False

    def _fresh(self):
        try:
            if not os.path.exists(DATA) or (time.time() - os.path.getmtime(DATA)) > REFRESH:
                subprocess.run([COLL], capture_output=True, timeout=30)
        except Exception:
            pass

    def _send(self, code, ctype, body):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        try:
            self.wfile.write(body)
        except Exception:
            pass

    def do_GET(self):
        p = urlparse(self.path).path
        if not self.authorized():
            self._send(401, "text/plain; charset=utf-8", b"unauthorized")
            return
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

    def log_message(self, fmt, *args):
        pass

if __name__ == "__main__":
    import sys
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
    print(f"DevMon listening on 0.0.0.0:{port}")
    ThreadingHTTPServer(("0.0.0.0", port), H).serve_forever()
PYEOF
chmod +x /usr/local/bin/devmon-web.py

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
echo " 管理页面: http://${IP}:${PORT}/?token=$(cat /etc/devmon.token)"
echo " 云端安全组请放行 TCP ${PORT} ${PORT_MSG}"
echo " 数据文件: /var/lib/devmon/devices.json"
echo " 手动刷新: sudo /usr/local/bin/devmon.sh"
echo " 服务日志: journalctl -u devmon-web -f"
echo "============================================================"
echo " [可选] 启用 DNS 请求统计（设备把这台服务器当 DNS 时执行）:"
echo "   sudo apt install -y dnsmasq"
echo "   echo -e 'log-queries\\nlog-facility=/var/log/dnsmasq.log' | sudo tee -a /etc/dnsmasq.conf"
echo "   sudo systemctl restart dnsmasq"
