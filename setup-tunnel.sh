#!/bin/bash
# Run this ONCE on your home PC to set up the Cloudflare tunnel.
# Prerequisites: cloudflared installed, a domain managed by Cloudflare.

set -e

TUNNEL_NAME="llama-tunnel"
DOMAIN="llm.yourdomain.com"   # <-- change to your actual domain

echo "==> Installing cloudflared..."
curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
  -o /usr/local/bin/cloudflared
chmod +x /usr/local/bin/cloudflared

echo "==> Logging in to Cloudflare (browser will open)..."
cloudflared tunnel login

echo "==> Creating tunnel: $TUNNEL_NAME"
cloudflared tunnel create $TUNNEL_NAME

TUNNEL_ID=$(cloudflared tunnel list | grep $TUNNEL_NAME | awk '{print $1}')
echo "==> Tunnel ID: $TUNNEL_ID"

echo "==> Copying credentials into cloudflared config directory..."
cp ~/.cloudflared/${TUNNEL_ID}.json ./cloudflared/${TUNNEL_ID}.json

echo "==> Updating config.yml with tunnel ID..."
sed -i "s/TUNNEL_ID/${TUNNEL_ID}/g" ./cloudflared/config.yml

echo "==> Creating DNS route: $DOMAIN -> $TUNNEL_NAME"
cloudflared tunnel route dns $TUNNEL_NAME $DOMAIN

echo ""
echo "Done. Tunnel ID: $TUNNEL_ID"
echo "Your llama-server will be reachable at: https://$DOMAIN"
echo "Now run: docker-compose up -d"
