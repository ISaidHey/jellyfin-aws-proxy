#!/bin/bash
# Pipe everything to cloud-init-output.log so CloudWatch can pick it up
exec > >(tee -a /var/log/cloud-init-output.log) 2>&1
set -eux
set -o pipefail

for i in {1..5}; do apt update -y && break || sleep 10; done
curl -Lo /tmp/amazon-cloudwatch-agent.deb https://s3.amazonaws.com/amazoncloudwatch-agent/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb
sudo dpkg -i /tmp/amazon-cloudwatch-agent.deb


cat <<'EOF' >/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json
{
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/cloud-init.log",
            "log_group_name": "/ec2/isaidhey/pigs-in-space",
            "log_stream_name": "{instance_id}-cloud-init",
            "retention_in_days": 7
          },
          {
            "file_path": "/var/log/cloud-init-output.log",
            "log_group_name": "/ec2/isaidhey/pigs-in-space",
            "log_stream_name": "{instance_id}-cloud-init-output",
            "retention_in_days": 7
          }
        ]
      }
    }
  }
}
EOF

chmod 600 /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json

/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config \
  -m ec2 \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json \
  -s

systemctl enable amazon-cloudwatch-agent
systemctl start amazon-cloudwatch-agent

apt install -y debian-keyring debian-archive-keyring apt-transport-https curl gpg

# Install Caddy (modern and secure)
mkdir -p /usr/share/keyrings
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
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


# 1️⃣ Generate server keys
SERVER_PRIV_KEY=$(wg genkey)
SERVER_PUB_KEY=$(echo "$SERVER_PRIV_KEY" | wg pubkey)

# 2️⃣ Optionally generate a client key
CLIENT_PRIV_KEY=$(wg genkey)
CLIENT_PUB_KEY=$(echo "$CLIENT_PRIV_KEY" | wg pubkey)

# 3️⃣ Write wg0.conf
cat <<EOF >/etc/wireguard/wg0.conf
[Interface]
Address = 10.10.0.1/24
ListenPort = 51820
PrivateKey = $SERVER_PRIV_KEY
SaveConfig = true

# Enable NAT for VPN clients
PostUp = iptables -t nat -A POSTROUTING -s 10.10.0.0/24 -o eth0 -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -s 10.10.0.0/24 -o eth0 -j MASQUERADE

[Peer]
# Example client
PublicKey = $CLIENT_PUB_KEY
AllowedIPs = 10.10.0.2/32
EOF

# 4️⃣ Enable IP forwarding
sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

# 5️⃣ Enable and start WireGuard
systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0

# 6️⃣ Output client config to /home/ubuntu/wg-client.conf
cat <<EOF >/home/ubuntu/wg-client.conf
[Interface]
PrivateKey = $CLIENT_PRIV_KEY
Address = 10.10.0.2/24
DNS = 1.1.1.1

[Peer]
PublicKey = $SERVER_PUB_KEY
Endpoint = ${ec2_public_ip}:51820
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF

chown ubuntu:ubuntu /home/ubuntu/wg-client.conf
chmod 600 /home/ubuntu/wg-client.conf
unset CLIENT_PRIV_KEY
unset CLIENT_PUB_KEY
