# DevMon 设备监控 维护手册 / 使用说明 (v6)

版本: v6 (2026-08-08 更新)
适用系统: Ubuntu 24.04 (需 root)
管理页面: `http://<本机IP>:<端口>/` (默认端口 8080)

---

## 1. 本次更新内容 (v5 → v6)

### 1.1 修复: 流量数据未采集
- 根因: 旧版 nftables `netmon` 计数表使用 `ip saddr @up` 查询一个从未填充的 map，且该内核
  不支持动态计数器 (`update`/`add` 返回 "Operation not supported")，导致上/下行永远为 0。
- 方案: 流量统计改由嗅探器 `devmon-sniff.py` (AF_PACKET 原始套接字) 按 IP 直接统计，
  每 5 秒写入 `/var/lib/devmon/traffic`；采集器优先读取该文件，nft 仅作兜底。
- 效果: 设备级上/下行、总上/下行均正常显示。

### 1.2 优化: IP 位置显示
- 新增 `/var/lib/devmon/geofix` 手工修正文件，优先级最高 (可把机房/CDN IP 标成真实位置)。
- 定位主源 `ip-api.com`，失败自动切换 `ipinfo.io` 备用，并把国家代码翻译成中文。
- 失败缓存缩短为 10 分钟自动重试；成功缓存 24 小时。
- 位置后附加 ISP/ASN 名称 (如 `[Cloudflare, Inc.]`)，便于识别 CDN / 云服务商。

### 1.3 新增: 设备端口 > 服务器端口
- 采集 conntrack 中每个连接的 `本机端口>服务器端口`，页面新增"端口(本机>服务器)"列，
  每台设备最多展示 20 组。

### 1.4 新增: 路由追踪 (traceroute)
- 页面每行外网设备新增"路由"按钮，弹出窗口逐跳显示路由路径。
- 后端 `/api/trace?ip=...` 调用 `traceroute` (已随安装自动安装)，结果缓存 30 分钟。

### 1.5 优化: 代理协议识别更广
- 采集器自动读取 daed 节点库 `/etc/daed/wing.db`，按节点端口自动识别
  `trojan-go` / `vless-reality` / `vless-grpc` / `vmess` 等协议。
- 嗅探器新增应用协议检测:
  - `anytls`: TLS ClientHello 中 ALPN 含 `itls`
  - `quic/h3`: UDP QUIC v1/v2 长包头 (可覆盖 hysteria2 / HTTP/3)
- `/var/lib/devmon/services` 模板扩展了 anytls / hysteria2 / ss / socks5 等示例端口。

---

## 2. 安装 / 重新安装

```bash
sudo bash install-devmon.sh [端口]      # 默认 8080
```

安装过程:
1. 系统检查 (需 root + nftables)
2. 安装依赖 `conntrack curl jq traceroute`
3. 初始化流量统计 (删除旧 nftables netmon 表，改为嗅探器采集)
4. 安装采集器 `devmon.sh` + 嗅探器 `devmon-sniff.py` (systemd 服务)
5. 安装 Web 页面 `devmon-web.py` (systemd 服务)
6. 启动并输出: 管理地址、初始密码、token、数据/日志路径

安装完成后页面提示中的随机密码只显示一次，用以下命令修改:

```bash
sudo bash devmon-passwd.sh [用户名]     # 默认 admin
```

---

## 3. 页面功能

| 列 | 说明 |
|----|------|
| 设备 | 设备名或 IP (可在 `names` 文件命名) |
| 设备系统 | 嗅探到的 OS/型号 (HTTP User-Agent / JA3 指纹) |
| 最近访问 | 嗅探到的访问域名 (TLS SNI) |
| 地点 | GeoIP 位置，含 ISP |
| 连接时长 | conntrack 或 first_seen 计算 |
| 传输协议 | tcp / udp / sctp / gre |
| 代理协议/服务 | 端口映射 + 嗅探识别 (vless/trojan/anytls/hysteria2…) |
| 端口(本机>服务器) | 设备端口到服务器端口的连接对 |
| 上行 / 下行 | 该 IP 发送 / 接收的字节数 |
| 路由 | 点击弹出 traceroute 逐跳路径 (外网设备) |

顶部卡片: 在线设备数、局域网总上行、局域网总下行 (均为内网口径)。
"全部 / 内网 / 外网" 筛选; 5 秒自动刷新。

---

## 4. 配置文件 (可手工编辑，改完自动生效)

### 4.1 `/var/lib/devmon/services` — 端口 → 协议
```
# 端口 服务名
80 vmess
443 vless
4433 hysteria2
8388 ss
8443 trojan
8881 vless-reality
8886 trojan-go
8890 vless-grpc
10086 anytls
1080 socks5
2053 hysteria2
```
daed 节点端口会自动识别，此处用于补充自定义代理端口 (如 ss / hysteria2 / anytls)。

### 4.2 `/var/lib/devmon/names` — IP → 设备名
```
# IP 设备名
192.168.0.137 客厅电视
```

### 4.3 `/var/lib/devmon/geofix` — IP → 手工定位 (优先级最高)
```
# IP 地点 类如
8.8.8.8 美国 圣路易斯 [CYBERCON]
```

### 4.4 `/var/lib/devmon/ja3db` — JA3 TLS 指纹 → 系统
```
# <32位ja3> 说明
13d6c21643a4d76c419bc34706a949d0 Linux curl (OpenSSL)
```

---

## 5. 日常维护

### 5.1 查看状态与日志
```bash
systemctl status devmon-web devmon-sniff      # 两个服务状态
journalctl -u devmon-web -f                    # Web 日志
cat /var/lib/devmon/collect.log                # 采集器错误日志
```

### 5.2 手动刷新数据
```bash
sudo /usr/local/bin/devmon.sh
```

### 5.3 重启服务
```bash
sudo systemctl restart devmon-web devmon-sniff
```

### 5.4 数据文件
| 文件 | 说明 |
|------|------|
| `/var/lib/devmon/devices.json` | 页面 API 数据 (每次刷新生成) |
| `/var/lib/devmon/traffic` | 按 IP 上/下行字节累计 (嗅探器每 5s 写) |
| `/var/lib/devmon/deviceinfo` | 设备 OS/型号/最近访问 (3 天过期) |
| `/var/lib/devmon/protocols` | 嗅探识别的应用协议 |
| `/var/lib/devmon/geo.cache` | GeoIP 缓存 (超 3000 行自动裁剪) |
| `/var/lib/devmon/traces.json` | traceroute 缓存 (30 分钟) |
| `/var/lib/devmon/state` | 时长状态文件 (设备消失 10 分钟重置) |

### 5.5 登录与授权
- 登录: `sudo bash devmon-passwd.sh` 设置账号密码。
- 免登录 token (适合脚本调用):
  `http://<IP>:<PORT>/api/devices?token=$(cat /etc/devmon.token)`
  或请求头 `X-Token: <token>`。
- API 端点: `/api/devices` (设备列表), `/api/trace?ip=<IP>` (路由追踪)。

### 5.6 可选: 本机 DNS 请求统计
```bash
sudo bash enable-dnslog.sh       # 开启 (页面显示 DNS TOP)
sudo bash disable-dnslog.sh      # 回滚
```

### 5.7 可选: 防火墙放行
```bash
sudo ufw allow <端口>/tcp         # 管理页面端口
```

---

## 6. 故障排查

| 现象 | 排查 |
|------|------|
| 流量全为 0 | `ls -l /var/lib/devmon/traffic` 看 mtime 是否 <30s；`systemctl status devmon-sniff` |
| 位置显示 "-" | 10 分钟后自动重试；或在 `geofix` 手工填写 |
| 协议列空白 | 检查 `services`/daed 节点端口是否正确；等嗅探器识别 (anytls/quic) |
| traceroute 无结果 | 确认已装 `traceroute`；目标屏蔽 ICMP/UDP 属正常，可看其它跳 |
| 页面登录不了 | 用 token 方式访问确认服务正常，再 `devmon-passwd.sh` 重置密码 |

---

## 7. 本包内容
```
install-devmon.sh                  # 一键安装脚本 (v6)
DevMon-维护手册.md                 # 本文档
```
