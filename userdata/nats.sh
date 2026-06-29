#!/bin/bash

set -e

exec > /var/log/userdata.log 2>&1

echo "Starting NATS installation..."

sleep 60

#####################################
# Detect Additional EBS Volume
#####################################

ROOT_DISK=$(findmnt -n -o SOURCE / | sed 's/p[0-9]*$//')

DISK=$(lsblk -dpno NAME | grep nvme | grep -v "$ROOT_DISK" | head -1)

while [ -z "$DISK" ]; do
    echo "Waiting for additional EBS volume..."
    sleep 10

    DISK=$(lsblk -dpno NAME | grep nvme | grep -v "$ROOT_DISK" | head -1)
done

echo "Using EBS Disk: $DISK"

#####################################
# Partition Disk
#####################################

if ! lsblk ${DISK}p1 >/dev/null 2>&1; then
  echo -e "n\np\n1\n\n\nw" | fdisk $DISK

  partprobe $DISK
  udevadm settle

  sleep 10
fi

#####################################
# Format Disk
#####################################

mkfs.ext4 -F ${DISK}p1

#####################################
# Mount NATS Data
#####################################

mkdir -p /data/nats

UUID=$(blkid -s UUID -o value ${DISK}p1)

grep -q "/data/nats" /etc/fstab || \
echo "UUID=${UUID} /data/nats ext4 defaults,nofail 0 2" >> /etc/fstab

mount -a

echo "Filesystem UUID: $UUID"

#####################################
# Install Docker
#####################################

apt-get update

apt-get install -y \
ca-certificates \
curl \
gnupg \
lsb-release

install -m 0755 -d /etc/apt/keyrings

curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
gpg --dearmor -o /etc/apt/keyrings/docker.gpg

chmod a+r /etc/apt/keyrings/docker.gpg

echo \
"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu \
$(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
| tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update

apt-get install -y \
docker-ce \
docker-ce-cli \
containerd.io \
docker-buildx-plugin \
docker-compose-plugin

systemctl enable docker
systemctl start docker

#####################################
# Get Instance Private IP
#####################################

PRIVATE_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)

echo "Private IP: ${PRIVATE_IP}"

#####################################
# Create Directories
#####################################

mkdir -p /etc/nats
mkdir -p /opt/nats
mkdir -p /home/ubuntu/nats-dashboard

#####################################
# Create NATS Configuration
#####################################

cat > /etc/nats/nats-server.conf <<EOF
listen: ${PRIVATE_IP}:4222

http: ${PRIVATE_IP}:8222

jetstream {

  store_dir: /data/nats

  max_memory_store: 1GB

  max_file_store: 16GB

}
EOF

#####################################
# Create Docker Compose
#####################################

cat > /opt/nats/docker-compose.yml <<EOF
version: "3.8"

services:

  nats:

    image: nats:2.10

    container_name: nats-server

    restart: unless-stopped

    ports:
      - "4222:4222"
      - "8222:8222"

    volumes:
      - /etc/nats/nats-server.conf:/etc/nats-server.conf
      - /data/nats:/data/nats

    command:
      - "-c"
      - "/etc/nats/nats-server.conf"
EOF

#####################################
# Create Dashboard config.json
#####################################

cat > /home/ubuntu/nats-dashboard/config.json <<EOF
{
  "server": {
    "name": "NATS Server",
    "url": "http://${PRIVATE_IP}:8222"
  },
  "hideServerInput": true
}
EOF

#####################################
# Create Dashboard Caddyfile
#####################################

cat > /home/ubuntu/nats-dashboard/Caddyfile <<EOF
:80 {

    root * /srv

    encode gzip

    @nats {

        path /varz* /connz* /jsz*

    }

    reverse_proxy @nats ${PRIVATE_IP}:8222 {

        header_up Host {host}

    }

    file_server

    try_files {path}.html

}
EOF

#####################################
# Start NATS
#####################################

cd /opt/nats

docker compose up -d

echo "NATS Server Started"

#####################################
# Pull Dashboard Image
#####################################

docker pull mdawar/nats-dashboard

#####################################
# Remove Existing Dashboard
#####################################

docker rm -f nats-dashboard >/dev/null 2>&1 || true

#####################################
# Start Dashboard
#####################################

docker run -d \
  --name nats-dashboard \
  -p 3000:80 \
  -v /home/ubuntu/nats-dashboard/config.json:/srv/config.json \
  -v /home/ubuntu/nats-dashboard/Caddyfile:/etc/caddy/Caddyfile \
  --restart unless-stopped \
  mdawar/nats-dashboard

#####################################
# Wait
#####################################

sleep 15

#####################################
# Verify Containers
#####################################

docker ps

#####################################
# Verify NATS
#####################################

curl http://${PRIVATE_IP}:8222/varz || true

#####################################
# Verify Dashboard
#####################################

curl http://localhost:3000 || true

echo "======================================"

echo "NATS Installation Completed"

echo "Private IP : ${PRIVATE_IP}"

echo "NATS Client Port : 4222"

echo "NATS Monitoring : http://${PRIVATE_IP}:8222"

echo "Dashboard : http://${PRIVATE_IP}:3000"

echo "======================================"
