#!/usr/bin/env bash
# OpenVPN Server Setup (Ubuntu 20.04/22.04/24.04)
# - UDP 1194 by default, subnet 10.8.0.0/24
# - EasyRSA PKI, one client profile exported
# - IP forwarding + iptables NAT via netfilter-persistent
set -euo pipefail

red()   { printf "\e[31m%s\e[0m\n" "$*"; }
green() { printf "\e[32m%s\e[0m\n" "$*"; }
yellow(){ printf "\e[33m%s\e[0m\n" "$*"; }

need_root() {
  if [[ $EUID -ne 0 ]]; then
    red "Please run as root (sudo -i; bash $0)"; exit 1
  fi
}

need_root
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y openvpn easy-rsa netfilter-persistent iptables-persistent

# ------------ inputs -------------
green "=== OpenVPN Server Setup ==="
read -r -p "OpenVPN protocol [udp/tcp, default udp]: " OVPN_PROTO
OVPN_PROTO="${OVPN_PROTO:-udp}"
read -r -p "OpenVPN port [default 1194]: " OVPN_PORT
OVPN_PORT="${OVPN_PORT:-1194}"
read -r -p "Client name (for .ovpn) [e.g. tr-vps]: " CLIENT_NAME
CLIENT_NAME="${CLIENT_NAME:-client1}"

# Optional port-forward through VPN server
read -r -p "Add public port-forward (DNAT) now? (y/N): " ADD_FWD
ADD_FWD="${ADD_FWD:-n}"

# ------------ PKI ---------------
EASYRSA_DIR="/etc/openvpn/easy-rsa"
mkdir -p "$EASYRSA_DIR"
if [[ ! -d "$EASYRSA_DIR/pki" ]]; then
  make-cadir "$EASYRSA_DIR"
fi
cd "$EASYRSA_DIR"

# Initialize PKI if not present
if [[ ! -d pki ]]; then
  ./easyrsa init-pki
fi

# Build CA & server cert (non-interactive, simple CNs)
if [[ ! -f pki/ca.crt ]]; then
  yes "" | ./easyrsa build-ca nopass
fi

if [[ ! -f pki/issued/server.crt ]]; then
  ./easyrsa build-server-full server nopass
fi

# Diffie-Hellman (EasyRSA 3 can use DH or ECDH; we'll use DH for classic setup)
if [[ ! -f pki/dh.pem ]]; then
  ./easyrsa gen-dh
fi

# TLS-auth key (optional but common)
if [[ ! -f /etc/openvpn/ta.key ]]; then
  openvpn --genkey secret /etc/openvpn/ta.key
fi

# ------------ server config ------------
cat > /etc/openvpn/server.conf <<EOF
port ${OVPN_PORT}
proto ${OVPN_PROTO}
dev tun
user nobody
group nogroup
persist-key
persist-tun
topology subnet
server 10.8.0.0 255.255.255.0
client-config-dir /etc/openvpn/ccd
ifconfig-pool-persist /etc/openvpn/ipp.txt
keepalive 10 120
cipher AES-256-GCM
ncp-ciphers AES-256-GCM:AES-128-GCM
auth SHA256
tls-server
ca ${EASYRSA_DIR}/pki/ca.crt
cert ${EASYRSA_DIR}/pki/issued/server.crt
key ${EASYRSA_DIR}/pki/private/server.key
dh ${EASYRSA_DIR}/pki/dh.pem
tls-auth /etc/openvpn/ta.key 0
explicit-exit-notify 1
verb 3
;push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 1.1.1.1"
push "dhcp-option DNS 9.9.9.9"

# Allow client-to-client if you want LAN-style
client-to-client
EOF

mkdir -p /etc/openvpn/ccd

# ------------ enable forwarding & NAT ------------
# Enable kernel IP forwarding
sysctl -w net.ipv4.ip_forward=1 >/dev/null
grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf

# Figure out public NIC (best guess)
PUB_IF=$(ip route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
: "${PUB_IF:=ens3}"

# NAT for VPN subnet out via public IF
iptables -t nat -C POSTROUTING -s 10.8.0.0/24 -o "${PUB_IF}" -j MASQUERADE 2>/dev/null || \
iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o "${PUB_IF}" -j MASQUERADE

netfilter-persistent save >/dev/null

# ------------ start OpenVPN ------------
systemctl enable --now openvpn@server

# ------------ create client ------------
cd "$EASYRSA_DIR"
if [[ ! -f "pki/issued/${CLIENT_NAME}.crt" ]]; then
  ./easyrsa build-client-full "${CLIENT_NAME}" nopass
fi

# Export inline .ovpn
OVPN_DIR="/root"
OVPN_FILE="${OVPN_DIR}/${CLIENT_NAME}.ovpn"
SERVER_IP=$(curl -fsS https://api.ipify.org || echo "YOUR_SERVER_IP")
cat > "${OVPN_FILE}" <<EOF
client
dev tun
proto ${OVPN_PROTO}
remote ${SERVER_IP} ${OVPN_PORT}
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
cipher AES-256-GCM
auth SHA256
verb 3
key-direction 1

<ca>
$(cat ${EASYRSA_DIR}/pki/ca.crt)
</ca>
<cert>
$(awk '/BEGIN/,/END/' ${EASYRSA_DIR}/pki/issued/${CLIENT_NAME}.crt)
</cert>
<key>
$(cat ${EASYRSA_DIR}/pki/private/${CLIENT_NAME}.key)
</key>
<tls-auth>
$(cat /etc/openvpn/ta.key)
</tls-auth>
EOF

# ------------ optional DNAT forward ------------
if [[ "${ADD_FWD,,}" == "y" ]]; then
  echo
  yellow "Configure DNAT (Public -> VPN client:port)"
  read -r -p "Public listen port (e.g. 61522): " PUB_PORT
  read -r -p "Destination VPN client IP (e.g. 10.8.0.2): " DST_IP
  read -r -p "Destination port (usually same as public): " DST_PORT
  read -r -p "Protocols to forward [udp/tcp/both] (default both): " FWD_PROTO
  FWD_PROTO="${FWD_PROTO:-both}"

  if [[ "${FWD_PROTO}" == "udp" || "${FWD_PROTO}" == "both" ]]; then
    iptables -t nat -A PREROUTING -i "${PUB_IF}" -p udp --dport "${PUB_PORT}" -j DNAT --to-destination "${DST_IP}:${DST_PORT}"
    iptables -A FORWARD -i "${PUB_IF}" -o tun0 -p udp --dport "${DST_PORT}" -d "${DST_IP}" -j ACCEPT
  fi
  if [[ "${FWD_PROTO}" == "tcp" || "${FWD_PROTO}" == "both" ]]; then
    iptables -t nat -A PREROUTING -i "${PUB_IF}" -p tcp --dport "${PUB_PORT}" -j DNAT --to-destination "${DST_IP}:${DST_PORT}"
    iptables -A FORWARD -i "${PUB_IF}" -o tun0 -p tcp --dport "${DST_PORT}" -d "${DST_IP}" -j ACCEPT
  fi

  netfilter-persistent save >/dev/null
  green "DNAT rules added and saved."
fi

# ------------ done ------------
echo
green "================= DONE ================="
systemctl status openvpn@server --no-pager || true
echo "Client profile: ${OVPN_FILE}"
echo "Copy it securely (e.g. scp): scp root@<server>:${OVPN_FILE} ."
echo "If you need to add more clients later:"
echo "  cd ${EASYRSA_DIR} && ./easyrsa build-client-full <name> nopass"
echo "  (then export another .ovpn similar to above)"
echo "========================================"
