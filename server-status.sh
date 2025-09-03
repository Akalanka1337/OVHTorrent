#!/usr/bin/env bash
# Torrent + VPN Server Status Checker with Connectivity Tests

set -euo pipefail

green(){ echo -e "\e[32m$*\e[0m"; }
red(){ echo -e "\e[31m$*\e[0m"; }
yellow(){ echo -e "\e[33m$*\e[0m"; }

cmd_exists() { command -v "$1" >/dev/null 2>&1; }

echo "========== Server Status =========="

# --- OpenVPN ---
if systemctl is-active --quiet openvpn@server; then
    green "[OK] OpenVPN server is running"
else
    red "[FAIL] OpenVPN server is NOT running"
fi

# --- qBittorrent ---
if systemctl is-active --quiet qbittorrent; then
    green "[OK] qBittorrent service is running"
else
    red "[FAIL] qBittorrent service is NOT running"
fi

QB_PORT=$(grep -E "^WebUI\\\\Port=" /root/.config/qBittorrent/qBittorrent.conf | cut -d= -f2 || echo "43121")
QB_BIND=$(grep -E "^Connection\\\\Interface=" /root/.config/qBittorrent/qBittorrent.conf | cut -d= -f2 || echo "any")
TORRENT_PORT=$(grep -E "^Session\\\\Port=" /root/.config/qBittorrent/qBittorrent.conf | cut -d= -f2 || echo "61522")

echo "qBittorrent WebUI port: ${QB_PORT}, Bind: ${QB_BIND}"
echo "qBittorrent torrent port: ${TORRENT_PORT}"

# --- File Browser ---
if systemctl is-active --quiet filebrowser; then
    green "[OK] File Browser is running"
else
    red "[FAIL] File Browser is NOT running"
fi

# --- Nginx ---
if systemctl is-active --quiet nginx; then
    green "[OK] Nginx is running"
    grep "server_name" /etc/nginx/sites-enabled/* 2>/dev/null || true
else
    yellow "[WARN] Nginx not running"
fi

# --- IP Forwarding ---
if sysctl net.ipv4.ip_forward | grep -q "1"; then
    green "[OK] IP forwarding enabled"
else
    red "[FAIL] IP forwarding is DISABLED"
fi

# --- iptables rules ---
echo
echo "=== iptables NAT/MASQUERADE rules ==="
iptables -t nat -L POSTROUTING -n -v --line-numbers | grep -E "MASQUERADE" || yellow "No MASQUERADE found"

echo
echo "=== iptables DNAT (port forwarding) rules ==="
iptables -t nat -L PREROUTING -n -v --line-numbers | grep -E "DNAT" || yellow "No DNAT rules found"

# --- Listening Ports ---
echo
echo "=== Listening ports (ss -lnptu) ==="
if cmd_exists ss; then
    ss -lnptu
else
    netstat -lnptu
fi

# --- Connectivity Tests ---
echo
echo "========== Connectivity Tests =========="

PUBLIC_IP=$(curl -s ifconfig.me || curl -s icanhazip.com || echo "unknown")
echo "Detected Public IP: ${PUBLIC_IP}"

# Test torrent port
if cmd_exists nc; then
    echo -n "Testing torrent port ${TORRENT_PORT} ... "
    if nc -z -u -w3 127.0.0.1 ${TORRENT_PORT} 2>/dev/null; then
        green "LISTENING locally"
    else
        red "NOT listening locally"
    fi
else
    yellow "nc (netcat) not installed, skipping local port test"
fi

# Test WebUI
if cmd_exists curl; then
    echo -n "Testing WebUI (http://127.0.0.1:${QB_PORT}) ... "
    if curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:${QB_PORT} | grep -q "200"; then
        green "OK (responds locally)"
    else
        red "FAIL (no local response)"
    fi
fi

# Test File Browser
echo -n "Testing File Browser (http://127.0.0.1:8080) ... "
if curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8080 | grep -q "200"; then
    green "OK (responds locally)"
else
    yellow "No response (might be bound elsewhere)"
fi

echo "========================================"
