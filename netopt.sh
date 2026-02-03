#!/usr/bin/env bash
set -e

echo "======================================="
echo " VPN NODE NETWORK OPTIMIZER"
echo " Low latency • No hard limits • Fairness"
echo "======================================="
echo

if [[ $EUID -ne 0 ]]; then
  echo "❌ Please run as root"
  exit 1
fi

echo "🔍 Detecting network interfaces..."
ip -o link show | awk -F': ' '{print $2}' | grep -v lo
echo

read -rp "➡️ Enter primary network interface (e.g. eth0): " IFACE
if ! ip link show "$IFACE" &>/dev/null; then
  echo "❌ Interface not found"
  exit 1
fi

echo
read -rp "➡️ Server port speed (1 or 10 Gbps) [1/10]: " PORT_SPEED
if [[ "$PORT_SPEED" != "1" && "$PORT_SPEED" != "10" ]]; then
  echo "❌ Invalid port speed"
  exit 1
fi

echo
read -rp "➡️ This node will serve (1) Xray, (2) WireGuard, or (3) Both? [1/2/3]: " PROTO

echo
echo "⚙️ Applying kernel network optimizations..."

SYSCTL_FILE="/etc/sysctl.d/99-vpn-lowlatency.conf"

cat > "$SYSCTL_FILE" <<EOF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864

net.core.netdev_max_backlog = 250000
net.ipv4.tcp_max_syn_backlog = 8192
net.core.somaxconn = 8192

net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_no_metrics_save = 1

net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
fs.file-max = 1048576
EOF

sysctl --system >/dev/null

echo "✅ sysctl applied"

echo
echo "⚙️ Applying queue discipline..."

tc qdisc del dev "$IFACE" root 2>/dev/null || true

if [[ "$PORT_SPEED" == "10" ]]; then
  tc qdisc add dev "$IFACE" root fq_codel target 3ms interval 100ms quantum 1514 ecn
else
  tc qdisc add dev "$IFACE" root fq_codel target 5ms interval 100ms quantum 1514 ecn
fi

echo "✅ fq_codel active on $IFACE"

echo
echo "⚙️ Disabling NIC offloads (latency-safe)..."

ethtool -K "$IFACE" gro off gso off tso off 2>/dev/null || true

RC_LOCAL="/etc/rc.local"
if [[ ! -f "$RC_LOCAL" ]]; then
  echo -e "#!/bin/bash\nexit 0" > "$RC_LOCAL"
  chmod +x "$RC_LOCAL"
fi

sed -i "/ethtool -K $IFACE/d" "$RC_LOCAL"
sed -i "s/^exit 0/ethtool -K $IFACE gro off gso off tso off\nexit 0/" "$RC_LOCAL"

echo "✅ NIC offloads disabled"

echo
echo "⚙️ IRQ balance optimization..."

systemctl stop irqbalance 2>/dev/null || true
systemctl disable irqbalance 2>/dev/null || true

echo "✅ irqbalance disabled"

echo
echo "======================================="
echo " 🎉 OPTIMIZATION COMPLETE"
echo "======================================="
echo
echo "Node summary:"
echo "- Interface     : $IFACE"
echo "- Port speed    : ${PORT_SPEED} Gbps"
echo "- Protocols     : $([[ $PROTO == 1 ]] && echo Xray || [[ $PROTO == 2 ]] && echo WireGuard || echo Xray + WireGuard)"
echo
echo "ℹ️ Reboot recommended but NOT required"
echo
