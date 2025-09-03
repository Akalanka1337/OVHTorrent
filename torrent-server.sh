#!/usr/bin/env bash
# Torrent Server Setup (Ubuntu 20.04/22.04/24.04)
# - qBittorrent-nox (root), File Browser, Nginx reverse proxy
# - Optional Let's Encrypt (with DNS sanity check)
# - No ufw/fail2ban installed/modified

set -euo pipefail

# ---------- helpers ----------
red()   { printf "\e[31m%s\e[0m\n" "$*"; }
green() { printf "\e[32m%s\e[0m\n" "$*"; }
yellow(){ printf "\e[33m%s\e[0m\n" "$*"; }

need_root() {
  if [[ $EUID -ne 0 ]]; then
    red "Please run as root (sudo -i; bash $0)"; exit 1
  fi
}

detect_pubip() {
  curl -fsS https://api.ipify.org || curl -fsS https://ifconfig.me || echo "UNKNOWN"
}

cmd_exists() { command -v "$1" >/dev/null 2>&1; }

pause() { read -r -p "Press ENTER to continue..."; }

# ---------- checks ----------
need_root
yellow "Updating apt metadata..."
apt-get update -y

# ---------- inputs ----------
echo
green "=== Torrent Server Setup ==="
read -r -p "Domain for File Browser (e.g. files.example.com) [leave blank to skip HTTPS reverse proxy]: " FB_DOMAIN
read -r -p "qBittorrent WebUI port [default 43121]: " QB_WEBUI_PORT
QB_WEBUI_PORT="${QB_WEBUI_PORT:-43121}"
read -r -p "qBittorrent listening (incoming) port for peers [default 61522]: " QB_LISTEN_PORT
QB_LISTEN_PORT="${QB_LISTEN_PORT:-61522}"
read -r -p "Bind qBittorrent to VPN interface tun0 only? (y/N): " BIND_TUN
BIND_TUN="${BIND_TUN:-n}"

read -r -p "OpenVPN client systemd unit name to wait for (e.g. openvpn-client@client). Leave blank if none: " OVPN_UNIT

# File Browser
read -r -p "File Browser internal HTTP port [default 8081]: " FB_PORT
FB_PORT="${FB_PORT:-8081}"
read -r -p "File Browser admin username [default admin]: " FB_USER
FB_USER="${FB_USER:-admin}"
while true; do
  read -r -s -p "File Browser admin password: " FB_PASS; echo
  read -r -s -p "Confirm password: " FB_PASS2; echo
  [[ "$FB_PASS" == "$FB_PASS2" && -n "$FB_PASS" ]] && break
  red "Passwords empty or do not match. Try again."
done

# HTTPS decision
USE_LETSENCRYPT="no"
if [[ -n "${FB_DOMAIN}" ]]; then
  read -r -p "Issue Let's Encrypt cert for ${FB_DOMAIN}? (y/N): " CH_LE
  [[ "${CH_LE,,}" == "y" ]] && USE_LETSENCRYPT="yes"
fi

# ---------- packages ----------
green "[1/6] Installing packages..."
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  qbittorrent-nox nginx curl unzip

if [[ "${USE_LETSENCRYPT}" == "yes" ]]; then
  apt-get install -y certbot python3-certbot-nginx
fi

# ---------- folders ----------
green "[2/6] Preparing directories..."
mkdir -p /root/Downloads/MainData
mkdir -p /etc/filebrowser
mkdir -p /root/.config/qBittorrent

# ---------- qBittorrent config ----------
green "[3/6] Configuring qBittorrent..."
QB_CONF="/root/.config/qBittorrent/qBittorrent.conf"
if [[ ! -f "$QB_CONF" ]]; then
  cat > "$QB_CONF" <<EOF
[Application]
FileLogger\Enabled=true

[LegalNotice]
Accepted=true

[Network]
Cookies=@Invalid()

[Preferences]
Bittorrent\LSD=false
Bittorrent\DHT=false
Bittorrent\PeX=false
Bittorrent\AnonymousMode=true
Bittorrent\Encryption=1
Connection\GlobalDLLimitAlt=0
Connection\GlobalDLLimit=0
Connection\GlobalUPLimit=0
Connection\PortRangeMin=${QB_LISTEN_PORT}
Downloads\SavePath=/root/Downloads/MainData/
WebUI\Address=0.0.0.0
WebUI\Port=${QB_WEBUI_PORT}
WebUI\CSRFProtection=true
WebUI\ClickjackingProtection=true
WebUI\CustomHTTPHeaders=X-Frame-Options:SAMEORIGIN
WebUI\HostHeaderValidation=false

EOF
fi

# enforce listen port (idempotent)
sed -i "s#^Connection\\\PortRangeMin=.*#Connection\\\PortRangeMin=${QB_LISTEN_PORT}#g" "$QB_CONF"
sed -i "s#^Downloads\\\SavePath=.*#Downloads\\\SavePath=/root/Downloads/MainData/#g" "$QB_CONF"
sed -i "s#^WebUI\\\Port=.*#WebUI\\\Port=${QB_WEBUI_PORT}#g" "$QB_CONF"
# Bind to tun0 only if requested
if [[ "${BIND_TUN,,}" == "y" ]]; then
  # Tell qBittorrent to bind to tun0 and ignore others
  grep -q '^Connection\\\Interface=' "$QB_CONF" 2>/dev/null || echo "Connection\\Interface=tun0" >> "$QB_CONF"
  sed -i "s#^Connection\\\Interface=.*#Connection\\\Interface=tun0#g" "$QB_CONF"
  grep -q '^Connection\\\InterfaceName=' "$QB_CONF" 2>/dev/null || echo "Connection\\InterfaceName=tun0" >> "$QB_CONF"
  sed -i "s#^Connection\\\InterfaceName=.*#Connection\\\InterfaceName=tun0#g" "$QB_CONF"
fi

# ---------- qBittorrent systemd ----------
QB_REQUIRES=""
QB_AFTER="network-online.target"
if [[ -n "${OVPN_UNIT}" ]]; then
  QB_REQUIRES="Requires=${OVPN_UNIT}"
  QB_AFTER="${QB_AFTER} ${OVPN_UNIT}"
fi

cat > /etc/systemd/system/qbittorrent.service <<EOF
[Unit]
Description=qBittorrent-nox (root)
Wants=network-online.target
After=${QB_AFTER}
${QB_REQUIRES}

[Service]
User=root
ExecStart=/usr/bin/qbittorrent-nox --webui-port=${QB_WEBUI_PORT}
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now qbittorrent.service

# ---------- File Browser ----------
green "[4/6] Installing & configuring File Browser..."
if ! cmd_exists filebrowser; then
  bash -c 'curl -fsSL https://raw.githubusercontent.com/filebrowser/get/master/get.sh | bash'
fi

# Ensure DB at /etc/filebrowser/filebrowser.db
if [[ ! -f /etc/filebrowser/filebrowser.db ]]; then
  filebrowser config init --database /etc/filebrowser/filebrowser.db -a 127.0.0.1
fi

# Configure root and port
filebrowser config set --database /etc/filebrowser/filebrowser.db --root /root/Downloads/MainData
filebrowser config set --database /etc/filebrowser/filebrowser.db --address 127.0.0.1
filebrowser config set --database /etc/filebrowser/filebrowser.db --port "${FB_PORT}" || true

# Create/ensure admin
if ! filebrowser users ls --database /etc/filebrowser/filebrowser.db | awk '{print $2}' | grep -qw "${FB_USER}"; then
  filebrowser users add "${FB_USER}" "${FB_PASS}" --perm.admin --database /etc/filebrowser/filebrowser.db
else
  filebrowser users update "${FB_USER}" --password "${FB_PASS}" --perm.admin --database /etc/filebrowser/filebrowser.db
fi

# File Browser systemd
cat > /etc/systemd/system/filebrowser.service <<EOF
[Unit]
Description=File Browser
After=network.target

[Service]
User=root
ExecStart=/usr/local/bin/filebrowser --database /etc/filebrowser/filebrowser.db --address 127.0.0.1 --port ${FB_PORT} --root /root/Downloads/MainData
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now filebrowser.service

# ---------- Nginx reverse proxy ----------
green "[5/6] Nginx reverse proxy..."
if [[ -n "${FB_DOMAIN}" ]]; then
  cat > /etc/nginx/sites-available/filebrowser.conf <<EOF
server {
    listen 80;
    server_name ${FB_DOMAIN};

    location / {
        proxy_pass http://127.0.0.1:${FB_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF

  ln -sf /etc/nginx/sites-available/filebrowser.conf /etc/nginx/sites-enabled/filebrowser.conf
  nginx -t
  systemctl reload nginx
else
  yellow "No domain provided: skipping reverse proxy. File Browser will remain available on http://127.0.0.1:${FB_PORT} (local only)."
fi

# ---------- Let's Encrypt (optional) ----------
if [[ "${USE_LETSENCRYPT}" == "yes" ]]; then
  green "[6/6] Let's Encrypt issuance for ${FB_DOMAIN}..."

  PUBIP="$(detect_pubip)"
  DNSIP="$(getent ahostsv4 "${FB_DOMAIN}" | awk '{print $1; exit}' || true)"

  echo "Public IP (detected): ${PUBIP}"
  echo "DNS A for ${FB_DOMAIN}: ${DNSIP}"
  if [[ -z "${DNSIP}" || -z "${PUBIP}" || "${DNSIP}" != "${PUBIP}" ]]; then
    red "DNS for ${FB_DOMAIN} does not point to this server's IP. Let's Encrypt will fail."
    read -r -p "Proceed anyway? (y/N): " PROCEED
    if [[ "${PROCEED,,}" != "y" ]]; then
      yellow "Skipping Let's Encrypt. You can run later: certbot --nginx -d ${FB_DOMAIN}"
      USE_LETSENCRYPT="no"
    fi
  fi

  if [[ "${USE_LETSENCRYPT}" == "yes" ]]; then
    # Try to get a cert and also enable HTTP->HTTPS redirect
    certbot --nginx -d "${FB_DOMAIN}" --redirect --agree-tos -m admin@"${FB_DOMAIN}" -n || {
      red "Certbot failed. You can retry later with: certbot --nginx -d ${FB_DOMAIN}"
    }
  fi
fi

# ---------- final info ----------
echo
green "================= DONE ================="
echo "qBittorrent WebUI (from your LAN/VPN): http://<SERVER-IP>:${QB_WEBUI_PORT}"
if [[ -n "${FB_DOMAIN}" ]]; then
  if [[ "${USE_LETSENCRYPT}" == "yes" ]]; then
    echo "File Browser (HTTPS): https://${FB_DOMAIN}"
  else
    echo "File Browser (HTTP via Nginx):  http://${FB_DOMAIN}"
    yellow "If you use Cloudflare Full/Strict, HTTPS will be handled by Cloudflare."
  fi
else
  echo "File Browser is bound to 127.0.0.1:${FB_PORT} (reverse proxy not set)."
fi
echo
echo "File Browser login: ${FB_USER} / (your password)"
echo "qBittorrent incoming port: ${QB_LISTEN_PORT}"
if [[ "${BIND_TUN,,}" == "y" ]]; then
  echo "qBittorrent binds to tun0 only."
fi
echo "========================================"
