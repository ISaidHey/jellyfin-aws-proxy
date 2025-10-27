#!/bin/bash
set -eux
set -o pipefail

apt update -y
apt install -y debian-keyring debian-archive-keyring apt-transport-https curl gpg

# Install Caddy (modern and secure)
mkdir -p /usr/share/keyrings
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy.list
apt update
apt install -y caddy wireguard wireguard-tools
apt-get clean

cat <<'EOF' >/etc/caddy/Caddyfile
# /etc/caddy/Caddyfile

media.example.com {
    encode zstd gzip

    reverse_proxy 10.0.2.2:8096  # replace with your Jellyfin WireGuard peer IP

    tls {
        dns route53 {
            max_retries 10
        }
    }

    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "DENY"
        Referrer-Policy "no-referrer-when-downgrade"
        Permissions-Policy "camera=(), microphone=(), geolocation=()"
    }
}

EOF

systemctl enable caddy
systemctl start caddy
systemctl enable wg-quick@wg0
systemctl enable amazon-ssm-agent
systemctl start amazon-ssm-agent
