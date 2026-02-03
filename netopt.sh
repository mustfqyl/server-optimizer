#!/usr/bin/env bash
set -e

echo "======================================="
echo " VPN NODE NETWORK OPTIMIZER"
echo "======================================="

if [[ $EUID -ne 0 ]]; then
  echo "❌ Run as root"
  exit 1
fi

echo
echo "🔍 Detecting default interface..."

DEFAULT_IFACE=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')

if [[ -z "$DEFAULT_IFACE" ]]; then
  echo "❌ Could not auto-detect interface"
  echo "Available interfaces:"
  ip -o link show | awk -F': ' '{print $2}' | grep -v lo
  read -rp "➡️ Enter interface manually: " IFACE
else
  echo "➡️ Detected interface: $DEFAULT_IFACE"
  read -rp "Press Enter to use [$DEFAULT_IFACE] or type another: " IFACE
  IFACE=${IFACE:-$DEFAULT_IFACE}
fi

echo
echo "✅ Using interface: $IFACE"

# ==== SAFE CHECK (NO set -e BREAK) ====
set +e
ip link show "$IFACE" >/dev/null 2>&1
RC=$?
set -e

if [[ $RC -ne 0 ]]; then
  echo "❌ Interface '$IFACE' does not exist"
  exit 1
fi

echo
echo "⚙️ Applying sysctl network tuning..."

cat >/etc/sysctl.d/99-vpn-lowlatency.conf <<EOF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.core.netdev_max_backlog = 250000
net.core.somaxconn = 8192
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_tw_reuse = 1
fs.file-max = 1048576
EOF

sysctl --system >/dev/null

echo "✅ sysctl applied"

echo
echo "⚙️ Applying fq_codel on $IFACE"

tc qdisc del dev "$IFACE" root 2>/dev/null || true
tc qdisc add dev "$IFACE" root fq_codel target 5ms interval 100ms quantum 1514 ecn

echo "✅ fq_codel active"

echo
echo "⚙️ Disabling NIC offloads"

ethtool -K "$IFACE" gro off gso off tso off 2>/dev/null || true

echo
echo "🎉 DONE — Network optimized"
echo "ℹ️ Reboot recommended (not mandatory)"
