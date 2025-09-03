# OVHTorrent – Automated Torrent & VPN Server Setup

> **Learn More & Full Guide:**  
> [Complete Guide: Setting up a Secure Torrent VPS with OpenVPN + VPS on OVH Cloud (2 Instances)](https://cyberscap.com/threads/complete-guide-setting-up-a-secure-torrent-vps-with-openvpn-vps-on-ovh-cloud-2-instances.57/)

---

## 🚀 Features

This repo provides **fully automated installation scripts** for Ubuntu servers:

- **Torrent Server (`torrent-server.sh`)**
  - Installs & configures **qBittorrent-nox** with WebUI
  - Sets up **File Browser** for file access & sharing
  - Configures **Nginx reverse proxy** with SSL (Cloudflare / Let's Encrypt)
  - Firewall & port forwarding support
  - Auto-start services with `systemd`

- **VPN Server (`vpn-server.sh`)**
  - Installs & configures **OpenVPN**
  - Handles keys, certificates, and client configs
  - Sets up NAT/iptables rules for secure routing
  - Auto-start on boot

- **Status Checker (`server-status.sh`)**
  - Checks if qBittorrent, File Browser, OpenVPN, and Nginx are running
  - Displays listening ports
  - Verifies torrent port forwarding
  - Tests connectivity for services

---

## 📦 Installation

Clone the repo:

```bash
git clone https://github.com/Akalanka1337/OVHTorrent.git
cd OVHTorrent
```

Or run scripts directly from GitHub:

### 1. Torrent Server

```bash
bash <(curl -s https://raw.githubusercontent.com/Akalanka1337/OVHTorrent/main/torrent-server.sh)
```

### 2. VPN Server

```bash
bash <(curl -s https://raw.githubusercontent.com/Akalanka1337/OVHTorrent/main/vpn-server.sh)
```

### 3. Server Status Checker

```bash
bash <(curl -s https://raw.githubusercontent.com/Akalanka1337/OVHTorrent/main/server-status.sh)
```

---

## 🖥️ Usage

### qBittorrent WebUI
- Default: `http://SERVER_IP:43121`  
- Or via domain (if set): `https://your-domain.com`

### File Browser
- Default: `http://SERVER_IP:8080`  
- Or via domain: `https://your-domain.com/filebrowser`

### OpenVPN
- Client configs are generated in `/etc/openvpn/client/`  
- Import `.ovpn` files into your VPN client

### Managing Services

```bash
# qBittorrent
systemctl restart qbittorrent

# File Browser
systemctl restart filebrowser

# OpenVPN
systemctl restart openvpn

# Nginx
systemctl restart nginx
```

---

## 🔍 Status Check

To check if everything is running:

```bash
bash <(curl -s https://raw.githubusercontent.com/Akalanka1337/OVHTorrent/main/server-status.sh)
```

This will show:

- ✅ Service status (running or stopped)  
- ✅ Active ports  
- ✅ Firewall/NAT rules  
- ✅ Connectivity test for torrent port & WebUI  

---

## ⚠️ Notes

- Supported on **Ubuntu 20.04 / 22.04** (root access required).  
- Best used on a **fresh VPS**.  
- For Cloudflare Full (Strict) SSL: ensure your domain DNS points to the VPS before running.  
- Default ports:
  - qBittorrent WebUI → `43121`
  - File Browser → `8080`
  - OpenVPN → `1194` (UDP)

---

## 📚 Learn More

👉 [Full step-by-step guide with troubleshooting](https://cyberscap.com/threads/complete-guide-setting-up-a-secure-torrent-vps-with-openvpn-vps-on-ovh-cloud-2-instances.57/)

