#!/bin/bash
# Pipe everything to cloud-init-output.log so CloudWatch can pick it up
exec > >(tee -a /var/log/cloud-init-output.log) 2>&1
set -eux
set -o pipefail

function installAWS() {
    curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
    unzip awscliv2.zip
    sudo ./aws/install
    aws --version
}

function installCloudWatchAgent() {
  curl -Lo /tmp/amazon-cloudwatch-agent.deb https://s3.amazonaws.com/amazoncloudwatch-agent/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb
  dpkg -i /tmp/amazon-cloudwatch-agent.deb

  cat <<'EOF' >/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json
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
}

function installCaddy() {
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

  touch /var/log/caddy.log
  chmod 640 /var/log/caddy.log

  systemctl daemon-reload
  systemctl enable caddy
  systemctl start caddy

  rm -rf /tmp/caddy-build /usr/local/go /root/go/go-build
}

function installWireGuard() {
  cat <<EOF >/etc/wireguard/wg0.conf
${wg0conf}
EOF

  sysctl -w net.ipv4.ip_forward=1
  echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

  systemctl enable wg-quick@wg0
  systemctl start wg-quick@wg0
}

function restoreCerts() {
  # One secret covers every proxied service's certs - Caddy stores them all
  # under the same acme directory, organized by hostname subfolder already.
  CERT_SECRET_NAME="caddy-certs-${project_name}"
  CERTS_DIR="/root/.local/share/caddy/certificates/acme-v02.api.letsencrypt.org-directory"

  echo "Checking for existing TLS certs in Secrets Manager: $CERT_SECRET_NAME"
  mkdir -p "$CERTS_DIR"

  if aws secretsmanager get-secret-value --secret-id "$CERT_SECRET_NAME" --region "${region}" >/tmp/secret.json 2>/dev/null; then
    echo "Found existing certs in Secrets Manager, restoring..."
    jq -r '.SecretBinary' /tmp/secret.json | base64 -d >/tmp/certs.tar.gz
    tar -xzf /tmp/certs.tar.gz -C "$CERTS_DIR"
  else
    echo "No existing certs found — will let Caddy issue new ones."
  fi
}

function backupCerts() {
  # --- Backup new Caddy certs to AWS Secrets Manager ---
  echo "Backing up TLS certs to Secrets Manager..."
  CERT_SECRET_NAME="caddy-certs-${project_name}"
  CERTS_DIR="/root/.local/share/caddy/certificates/acme-v02.api.letsencrypt.org-directory"

  EXPECTED_CERTS=(
%{ for svc in services ~}
    "$CERTS_DIR/${svc.subdomain}.${domain}/${svc.subdomain}.${domain}.crt"
%{ endfor ~}
  )

  for i in {1..30}; do
    all_found=true
    for f in "$${EXPECTED_CERTS[@]}"; do
      [ -f "$f" ] || all_found=false
    done
    if [ "$all_found" = true ]; then
      echo "All certificates found — continuing."
      break
    fi
    echo "Waiting for Caddy to finish certificate issuance..."
    sleep 10
  done

  missing=false
  for f in "$${EXPECTED_CERTS[@]}"; do
    [ -f "$f" ] || { echo "ERROR: missing $f"; missing=true; }
  done
  if [ "$missing" = true ]; then
    echo "ERROR: Not all certificates were found after waiting. Skipping backup."
    return 1
  fi

  set +x
  CERTS_ARCHIVE="/tmp/certs.tar.gz"
  tar -czf "$CERTS_ARCHIVE" -C "$CERTS_DIR" .
  CERTS_BASE64=$(base64 -w 0 "$CERTS_ARCHIVE")

  if ! aws secretsmanager create-secret \
    --name "$CERT_SECRET_NAME" \
    --description "TLS certs for ${project_name}" \
    --region "${region}" \
    --secret-binary "$CERTS_BASE64" 2>/dev/null; then
    echo "Secret already exists, updating..."
    aws secretsmanager put-secret-value \
      --secret-id "$CERT_SECRET_NAME" \
      --region "${region}" \
      --secret-binary "$CERTS_BASE64"
  fi
  set -x
  echo "Certs synced to Secrets Manager successfully."

  rm -f /tmp/certs.tar.gz
}

for i in {1..5}; do apt update -y && break || sleep 10; done

installCloudWatchAgent

apt install -y \
  apt-transport-https \
  curl \
  debian-archive-keyring \
  debian-keyring \
  gpg \
  jq \
  unzip \
  wireguard \
  wireguard-tools \
  zip

installAWS

restoreCerts

installCaddy
installWireGuard

backupCerts

apt-get clean
