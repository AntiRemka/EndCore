#!/bin/bash
# ============================================
#   Classic MTProto Proxy (для MTProxyBot)
# ============================================

set -e

echo "Installing classic MTProto proxy..."

# 1. install docker
if ! command -v docker &>/dev/null; then
    apt-get update
    apt-get install -y docker.io
    systemctl enable --now docker
fi

# 2. generate secret (32 hex)
SECRET=$(openssl rand -hex 16)

# 3. get server ip
IP=$(curl -4 -s ifconfig.me)

echo "Server IP: $IP"
echo "Secret: $SECRET"

# 4. download proxy
mkdir -p /opt/mtproto
cd /opt/mtproto

curl -s https://core.telegram.org/getProxyConfig -o proxy-multi.conf
curl -s https://core.telegram.org/getProxySecret -o proxy-secret

# 5. stop old container
docker rm -f mtproto 2>/dev/null || true

# 6. run proxy
docker run -d \
  --name mtproto \
  --restart always \
  -p 8443:443 \
  -v /opt/mtproto:/data \
  telegrammessenger/proxy:latest \
  -p 443 \
  -H $SECRET \
  -C proxy-secret \
  -c proxy-multi.conf \
  --aes-pwd proxy-secret proxy-multi.conf

echo ""
echo "=================================="
echo "Classic proxy installed"
echo ""
echo "Send this to MTProxyBot:"
echo ""
echo "$IP"
echo "8443"
echo "$SECRET"
echo "=================================="
