#!/bin/bash

set -e

exec > /var/log/userdata.log 2>&1

echo "Starting Aerospike installation..."

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
# Mount Aerospike Data
#####################################

mkdir -p /data/aerospike

UUID=$(blkid -s UUID -o value ${DISK}p1)

echo "Filesystem UUID: $UUID"

grep -q "$UUID" /etc/fstab || \
echo "UUID=${UUID} /data/aerospike ext4 defaults,nofail 0 2" >> /etc/fstab

mount -a

#####################################
# Install Docker
#####################################

while fuser /var/lib/dpkg/lock >/dev/null 2>&1 || \
      fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1
do
    echo "Waiting for apt lock..."
    sleep 5
done

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

while fuser /var/lib/dpkg/lock >/dev/null 2>&1 || \
      fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1
do
    echo "Waiting for apt lock..."
    sleep 5
done

apt-get install -y \
docker-ce \
docker-ce-cli \
containerd.io \
docker-buildx-plugin \
docker-compose-plugin

systemctl enable docker

systemctl start docker

#####################################
# Create Directories
#####################################

mkdir -p /opt/aerospike

mkdir -p /opt/aerospike/config

mkdir -p /data/aerospike

#####################################
# Generate aerospike.conf
#####################################

cat > /opt/aerospike/config/aerospike.conf << 'EOF'
service {
    proto-fd-max 15000
    cluster-name cakery
}

logging {
    console {
        context any info
    }
}

network {

    service {
        address any
        port 3000
    }

    heartbeat {
        mode mesh

        port 3002

        interval 150

        timeout 10
    }

    fabric {
        port 3001
    }

}

namespace unoDetect {

    replication-factor 2

    nsup-period 24h

    nsup-threads 5

    default-ttl 90D

    storage-engine device {

        file /data/aerospike/unoDetect.dat

        filesize 20G

        flush-size 256K

    }

}
EOF
#####################################
# Generate docker-compose.yml
#####################################

cat > /opt/aerospike/docker-compose.yml << 'EOF'
version: "3.9"

services:

  aerospike:

    image: aerospike/aerospike-server:7.1.0.5

    container_name: aerospike

    network_mode: host

    privileged: true

    ulimits:
      nofile:
        soft: 65535
        hard: 65535

    volumes:
      - /opt/aerospike/config:/etc/aerospike
      - /data/aerospike:/data/aerospike

    command: --config-file /etc/aerospike/aerospike.conf

    restart: always

  aql:

    image: aerospike/aerospike-tools:latest

    container_name: aerospike-aql

    network_mode: host

    depends_on:
      - aerospike

    entrypoint:
      - tail
      - -f
      - /dev/null

    restart: always
EOF

#####################################
# Start Aerospike
#####################################

cd /opt/aerospike

docker compose up -d

#####################################
# Verify
#####################################

sleep 15

docker ps -a

echo ""

echo "===================================="

echo "Aerospike Installation Completed"

echo "===================================="

df -h

echo ""

mount | grep aerospike

echo ""

cat /etc/fstab

echo ""

docker ps

echo ""

docker logs aerospike --tail 50

echo ""

echo "===================================="

echo "Completed Successfully"

echo "===================================="
