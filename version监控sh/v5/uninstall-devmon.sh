#!/bin/bash
# ============================================================
# DevMon 卸载脚本 — 清理安装脚本产生的全部内容
# 用法: sudo bash uninstall-devmon.sh
# ============================================================
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "[!] 请用 root 执行: sudo bash uninstall-devmon.sh"
  exit 1
fi

echo "==> 1/6 停止并删除 Web 服务"
systemctl stop devmon-web 2>/dev/null || true
systemctl disable devmon-web 2>/dev/null || true
rm -f /etc/systemd/system/devmon-web.service
systemctl daemon-reload

echo "==> 2/6 删除脚本与数据"
rm -f /usr/local/bin/devmon.sh
rm -f /usr/local/bin/devmon-web.py
rm -f /etc/devmon.token
rm -rf /var/lib/devmon

echo "==> 3/6 移除 nftables 记账表"
nft delete table inet netmon 2>/dev/null || true
rm -f /etc/nftables.netmon

echo "==> 4/6 移除开机自启记录"
sed -i '/nftables\.netmon/d' /etc/crontab 2>/dev/null || true

echo "==> 5/6 [可选] 卸载安装的依赖包 (conntrack)"
read -r -p "是否同时卸载 conntrack？(y/N) " ans
if [ "${ans:-N}" = "y" ] || [ "${ans:-N}" = "Y" ]; then
  apt-get remove -y -qq conntrack
  echo "    conntrack 已卸载 (curl/jq 为系统常用工具，保留)"
fi

echo "==> 6/6 清理完成"
echo "  说明: 若启用过 DNS 统计，dnsmasq 及 /etc/dnsmasq.conf 中的配置需手动处理。"
