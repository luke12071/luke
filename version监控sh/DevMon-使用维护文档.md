# DevMon 使用与维护文档

轻量设备监控系统（Ubuntu 24.04 + Web 管理页面），v5。

目标场景：Ubuntu 云服务器，监控**谁在连这台服务器**——在线设备、系统/型号（尽力而为嗅探）、地点、连接时长、传输协议、代理服务、上下行流量、本机 DNS 统计，并有登录保护的管理页面。

---

## 1. 组件与文件清单

| 文件 | 作用 |
|---|---|
| `/usr/local/bin/devmon.sh` | 采集器 v5：设备发现、时长、流量、GeoIP、协议、服务映射、设备信息合并、DNS 统计，输出 JSON |
| `/usr/local/bin/devmon-sniff.py` | 设备信息嗅探器 v1：抓入站首个数据包，解析 HTTP UA 与 TLS SNI/JA3 |
| `/usr/local/bin/devmon-web.py` | Web 管理页面 v5（登录鉴权 + 管理页 + JSON API） |
| `/usr/local/bin/devmon-passwd.sh` | 修改 Web 登录密码 |
| `/usr/local/bin/enable-dnslog.sh` | 开启本机 DNS 请求统计（dnsmasq 抓取） |
| `/usr/local/bin/disable-dnslog.sh` | 关闭并回滚 DNS 统计配置 |
| `/etc/systemd/system/devmon-web.service` | Web 服务（systemd） |
| `/etc/systemd/system/devmon-sniff.service` | 嗅探服务（systemd） |
| `/etc/nftables.netmon` | nftables 流量记账表（开机由 crontab 恢复） |

### 数据文件（`/var/lib/devmon/`）

| 文件 | 内容 |
|---|---|
| `devices.json` | 采集结果（页面/API 直接读取） |
| `deviceinfo` | 嗅探结果 TSV：`IP  系统  型号  最近访问域名  最后活动时间` |
| `ja3db` | JA3 指纹 → 客户端/系统 映射库（可编辑） |
| `services` | 端口 → 服务名 映射（如 `8388 ss`） |
| `names` | IP → 设备名 映射（可编辑） |
| `geo.cache` | GeoIP 定位缓存（24 小时有效） |
| `state` | 连接时长兜底的 first_seen 记录 |
| `collect.log` | 采集器错误日志 |

### 安全文件

| 文件 | 内容 |
|---|---|
| `/etc/devmon.auth` | 登录账号（用户名/盐/迭代/哈希，PBKDF2-SHA256，权限 600） |
| `/etc/devmon.token` | 旧式 API 备用 token（URL `?token=` 或 `X-Token` 头） |

---

## 2. 安装

### 2.1 前置条件

- Ubuntu 24.04（其他版本会提示但可继续尝试）
- root 权限，可联网（GeoIP 查询、apt 安装）
- 云端安全组需放行 Web 端口（默认 `8080/tcp`）
- 需要 `nftables`、`python3`（Ubuntu 自带）

### 2.2 执行安装

```bash
# 方式一：从路由器/内网下载后执行
curl -o install-devmon.sh http://192.168.0.226/download/install-devmon.sh
sudo bash install-devmon.sh          # 默认端口 8080
# 或指定端口
sudo bash install-devmon.sh 9000
```

安装脚本依次执行：系统检查 → 安装依赖（conntrack/curl/jq）→ 初始化 nftables 记账表 → 安装采集器 → 生成映射模板 → 安装嗅探器 + systemd 服务 → 安装 Web 页面 + DNS 日志/改密工具 → 启动服务。

安装结束会打印：

```
管理页面: http://<服务器IP>:8080/    (需要登录)
登录账号: admin
登录密码: <随机生成的密码>           ← 首次安装自动生成
```

### 2.3 首次登录

1. 浏览器打开 `http://<服务器IP>:8080/`
2. 用 `admin` + 安装时打印的密码登录
3. 页面每 5 秒自动刷新（首次打开会触发采集器运行）

### 2.4 安装后自检

```bash
systemctl status devmon-web devmon-sniff     # 两个服务应 active
jq -r '.devices[].ip' /var/lib/devmon/devices.json   # 已有在线设备
cat /var/lib/devmon/deviceinfo                # 嗅探到的设备信息
```

---

## 3. 使用指南

### 3.1 Web 页面

| 栏目 | 说明 |
|---|---|
| 顶部卡片 | 在线设备数、总上行、总下行 |
| 设备表 | 设备名/IP、系统与型号、最近访问域名、地点、连接时长、传输协议、服务、上行、下行 |
| 筛选 | 全部 / 内网 / 外网（按 IP 段判断） |
| DNS TOP | 本机 DNS 请求统计（需先启用 enable-dnslog.sh） |

设备名显示优先级：`names` 映射 > 嗅探到的型号 > IP。

### 3.2 给设备命名

```bash
sudo nano /var/lib/devmon/names
# 格式: IP 设备名   （# 开头为注释）
203.0.113.5 我的手机
```
改完刷新页面即生效。

### 3.3 标注代理服务

```bash
sudo nano /var/lib/devmon/services
# 格式: 端口 服务名   （# 开头为注释）
443 vless
8388 ss
8443 trojan
```
设备连到对应端口时，页面"服务"列会显示该标签。默认模板已含 3 个常见项。

### 3.4 修改登录密码

```bash
sudo bash devmon-passwd.sh          # 修改 admin 密码
sudo bash devmon-passwd.sh alice    # 或设置其他用户名
```

### 3.5 开启本机 DNS 统计

```bash
sudo bash enable-dnslog.sh
```
原理：本机 DNS 查询由 `dnsmasq(127.0.0.1:53)` 代理并记日志，systemd-resolved 上游指向它，日志落到 `/var/log/dnsmasq.log`，页面自动展示 TOP 25。回滚：

```bash
sudo bash disable-dnslog.sh
```
（会备份并还原 `/etc/systemd/resolved.conf`。）

### 3.6 旧版 API（备用入口）

- URL：`http://<IP>:8080/?token=<TOKEN>` 或
- 请求头：`X-Token: <TOKEN>`，TOKEN 见 `/etc/devmon.token`
- 数据接口：`GET /api/devices`（返回 devices.json）

---

## 4. 功能实现原理

### 4.1 在线设备发现

- **conntrack** 优先：解析连接表里的 `src=IP dport=端口`，同时得到传输协议（tcp/udp/sctp/gre）
- **ss** 兜底：`ss -tnH` 里远端 IP 非本机/非 0.0.0.0 的已建立连接

### 4.2 连接时长

- 优先用 conntrack 的 `[START]` 时间戳（需内核开启 `CONFIG_NF_CONNTRACK_TIMESTAMP`）
- 不支持时用 `first_seen` 状态文件兜底
- 设备从连接表消失 10 分钟后时长重置

### 4.3 上下行流量

- 安装时建立 nftables `inet netmon` 表（`up`/`down` 两个 map + counter）
- 每台设备的上行/下行累计字节数由内核计数，采集时读表即可，不额外抓包

### 4.4 地理位置

- 内网 IP（`10./192.168./172.16-31./100.64-127./127./169.254.`）直接标记"内网"
- 公网 IP 查询 `http://ip-api.com/json/<IP>?lang=zh-CN`，结果缓存 24 小时到 `geo.cache`

### 4.5 传输协议与代理服务识别

- 协议：conntrack 记录的 tcp/udp 等
- 服务：按"本地端口"对照 `services` 文件，标注 vless/ss/trojan 等

### 4.6 设备系统/型号嗅探（尽力而为）

嗅探器监听所有网卡的入站 TCP **首个数据包**，不做持续抓包：

| 流量类型 | 解析内容 |
|---|---|
| HTTP 明文 | User-Agent → 系统/型号（iOS/Android/Windows/macOS/Linux/curl） |
| TLS 握手 | SNI（访问域名） + JA3 指纹（对照 `ja3db` 推断客户端） |

- 结果写入 `deviceinfo`，采集器合并进 `devices.json`
- JA3 实现符合规范：握手版本转十进制、过滤 GREASE 值（RFC 8701）、扩展按出现顺序十进制
- `ja3db` 可编辑扩充：查真实指纹 https://ja3er.com 后回填

> **重要限制**：vless/ss/trojan 等加密隧道内部的流量无法解析（只能看到"连到哪个端口"，看不到里层内容）。系统/型号识别依赖 HTTP UA 或 TLS SNI+JA3，属尽力而为，不是 100% 准确。

### 4.7 本机 DNS 统计

- dnsmasq 独立配置（只监听 127.0.0.1，不影响局域网解析）
- `log-queries` 记所有查询到 `/var/log/dnsmasq.log`
- 上游公共 DNS：223.5.5.5 / 119.29.29.29 / 1.1.1.1 / 8.8.8.8

### 4.8 登录安全

- 密码：PBKDF2-SHA256，20 万次迭代，随机盐，存 `/etc/devmon.auth`（600 权限）
- 登录：表单 POST `/login`，成功后下发 `HttpOnly + SameSite` 会话 Cookie，7 天有效
- 登出：`/logout` 同时失效服务端会话
- 页面/API 未登录一律 302 到登录页
- 旧 `?token=` 作为 API 备用通道保留

---

## 5. 升级与修复

```bash
curl -o fix-devmon.sh http://192.168.0.226/download/fix-devmon.sh
sudo bash fix-devmon.sh
```

`fix-devmon.sh` 用于版本升级（v4 → v5）：
- 覆盖采集器与 Web 页面到 v5
- 安装/更新嗅探器与 systemd 服务
- 生成 `ja3db` 模板（已存在则不覆盖）
- 不覆盖你已有的 `names`、`services`、`/etc/devmon.auth` 配置
- 结束打印自检结果

升级前建议先备份配置：

```bash
sudo cp -r /var/lib/devmon /var/lib/devmon.bak.$(date +%F)
sudo cp /etc/devmon.auth /etc/devmon.auth.bak
```

---

## 6. 常见问题与排错

| 现象 | 排查 |
|---|---|
| 页面打开转登录页 | 密码在 `/etc/devmon.auth`，用 `devmon-passwd.sh` 重设 |
| 没有设备数据 | `systemctl status devmon-web`；`cat /var/lib/devmon/collect.log`；确认 conntrack/ss 可用 |
| 嗅探不到系统/型号 | `systemctl status devmon-sniff`（需 root/CAP_NET_RAW）；加密隧道流量本就看不了；等 5 秒落盘 `deviceinfo` |
| 流量一直是 0 | `nft list map inet netmon up` 是否存在；不存在则重跑安装脚本 |
| 时长不准确 | conntrack 无 `[START]` 时会退化为 first_seen 近似值 |
| 地点显示"-" | 服务器无法访问 ip-api.com，或缓存过期（24h） |
| DNS 列表空 | 未执行 `enable-dnslog.sh`，或 `/var/log/dnsmasq.log` 无权限读 |

**通用排错**：先看两个服务的状态与日志，再读 `collect.log`：

```bash
systemctl status devmon-web devmon-sniff
journalctl -u devmon-web -n 20 --no-pager
cat /var/lib/devmon/collect.log
```

---

## 7. 卸载

```bash
curl -o uninstall-devmon.sh http://192.168.0.226/download/uninstall-devmon.sh
sudo bash uninstall-devmon.sh
```

卸载内容：
- 停止并删除 `devmon-web`、`devmon-sniff` 两个 systemd 服务
- 删除全部脚本（采集器/嗅探器/Web/改密/DNS 日志工具）
- 删除 `/etc/devmon.auth`、`/etc/devmon.token`
- 删除 `/var/lib/devmon` 全部数据（含你的映射配置，**卸载前先备份**）
- 删除 nftables `netmon` 表与 `crontab` 开机记录
- 可选询问是否卸载 `conntrack`（默认保留）
- 自动检测并回滚 DNS 日志配置

> 该卸载器**只适用于 systemd 系（Debian/Ubuntu）**，且**只针对 DevMon**。不要拿到 OpenWrt/iStoreOS 上跑。

---

## 8. 安全注意事项

- Web 页面**未启用 HTTPS**：数据（含登录会话）走明文。建议用安全组把 `8080/tcp` 限制到你的来源 IP
- 嗅探器以 root 运行（AF_PACKET raw socket 需要 root 或 CAP_NET_RAW）
- `deviceinfo`/`devices.json` 含设备访问过的域名（SNI/Host），注意不要外泄
- 更新 `ja3db` 时只放可信来源的指纹

---

## 9. 发布版本（路由器 /www/download）

| 文件 | 校验和 (md5) |
|---|---|
| `install-devmon.sh` | `8c750a75a9836fecfb6fe563c2b661d0` |
| `fix-devmon.sh` | `c558d1637bd6cfbdcd27331f7a358f63` |
| `uninstall-devmon.sh` | `02f1b74fe61a05124ac32c041a24c4f7` |

下载地址：`http://192.168.0.226/download/<文件名>`
