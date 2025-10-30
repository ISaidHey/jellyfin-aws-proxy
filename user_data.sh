#!/bin/bash
# Pipe everything to cloud-init-output.log so CloudWatch can pick it up
exec > >(tee -a /var/log/cloud-init-output.log) 2>&1
set -eux
set -o pipefail

for i in {1..5}; do apt update -y && break || sleep 10; done
curl -Lo /tmp/amazon-cloudwatch-agent.deb https://s3.amazonaws.com/amazoncloudwatch-agent/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb
dpkg -i /tmp/amazon-cloudwatch-agent.deb

cat <<EOF >/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json
${cw_agent_json}
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

mkdir -p /tmp/caddy-build
cd /tmp/caddy-build
apt update && apt install -y git

curl -LO https://go.dev/dl/go1.25.3.linux-amd64.tar.gz
rm -rf /usr/local/go
tar -C /usr/local -xzf go1.25.3.linux-amd64.tar.gz
export PATH=/usr/local/go/bin:/root/go/bin:$PATH
export GOPATH=/root/go
export GOCACHE=/tmp/gocache
export HOME=/root
mkdir -p "$HOME"

git clone https://github.com/caddyserver/caddy.git
cd caddy
go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest
/root/go/bin/xcaddy build --with github.com/caddy-dns/route53

# Move the built caddy binary to /usr/bin
mv caddy /usr/bin/caddy
chmod +x /usr/bin/caddy

apt update
apt install -y wireguard wireguard-tools
apt-get clean

mkdir -p /etc/caddy
cat <<'EOF' >/etc/caddy/Caddyfile
${caddyfile}
EOF

caddy validate --config /etc/caddy/Caddyfile

cat <<'EOF' >/etc/systemd/system/caddy.service
[Unit]
Description=Caddy web server
Documentation=https://caddyserver.com/docs/
After=network.target

[Service]
ExecStart=/usr/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/bin/caddy reload --config /etc/caddy/Caddyfile
Restart=on-failure
User=root
Group=root
AmbientCapabilities=CAP_NET_BIND_SERVICE
StandardOutput=append:/var/log/caddy.log
StandardError=append:/var/log/caddy.log

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable caddy
systemctl start caddy

cat <<EOF >/etc/wireguard/wg0.conf
${wg0conf}
EOF

sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0
