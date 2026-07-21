#!/bin/bash

set -e

exec > /var/log/userdata.log 2>&1

echo "===== MongoDB Installation Started ====="

sleep 60

########################################
# Detect Additional EBS Volume
########################################

ROOT_DISK=$(findmnt -n -o SOURCE / | sed 's/p[0-9]*$//')

DISK=$(lsblk -dpno NAME | grep nvme | grep -v "$ROOT_DISK" | head -1)

while [ -z "$DISK" ]
do
    echo "Waiting for EBS Volume..."
    sleep 10
    DISK=$(lsblk -dpno NAME | grep nvme | grep -v "$ROOT_DISK" | head -1)
done

echo "Using Disk : $DISK"

########################################
# Partition Disk
########################################

if ! lsblk ${DISK}p1 >/dev/null 2>&1
then
    echo -e "n\np\n1\n\n\nw" | fdisk $DISK
    partprobe $DISK
    udevadm settle
    sleep 5
fi

########################################
# Format
########################################

if ! blkid ${DISK}p1 >/dev/null 2>&1; then
    echo "Formatting ${DISK}p1..."
    mkfs.ext4 -F ${DISK}p1
else
    echo "Filesystem already exists. Skipping format."
fi

########################################
# Mount
########################################

mkdir -p /mongodb-data

UUID=$(blkid -s UUID -o value ${DISK}p1)

grep -q "$UUID" /etc/fstab || \
echo "UUID=${UUID} /mongodb-data ext4 defaults,nofail 0 2" >> /etc/fstab

mount -a

########################################
# Directories
########################################

mkdir -p /mongodb-data/logs

mkdir -p /opt/mongodb

########################################
# Permissions
########################################

chown -R 999:999 /mongodb-data

chmod -R 755 /mongodb-data

########################################
# Wait for Apt Lock
########################################

while fuser /var/lib/dpkg/lock >/dev/null 2>&1 || \
      fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1
do
    echo "Waiting for apt lock..."
    sleep 5
done

########################################
# Install Packages
########################################

apt-get update

apt-get install -y \
curl \
unzip \
jq \
awscli \
ca-certificates \
gnupg \
lsb-release

########################################
# Install Docker
########################################

install -m 0755 -d /etc/apt/keyrings

curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
| gpg --dearmor -o /etc/apt/keyrings/docker.gpg

chmod a+r /etc/apt/keyrings/docker.gpg

echo \
"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu \
$(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
| tee /etc/apt/sources.list.d/docker.list >/dev/null

apt-get update

apt-get install -y \
docker-ce \
docker-ce-cli \
containerd.io \
docker-buildx-plugin \
docker-compose-plugin

systemctl enable docker

systemctl start docker

########################################
# Verify
########################################

docker --version

docker compose version

aws --version

jq --version

########################################
# Read Secret
########################################

SECRET=$(aws secretsmanager get-secret-value \
    --secret-id terraform-mongodb \
    --query SecretString \
    --output text)
if [ -z "$SECRET" ]; then
    echo "ERROR: Failed to retrieve secret."
    exit 1
fi

MONGO_USER=$(echo "$SECRET" | jq -r '.username')

MONGO_PASSWORD=$(echo "$SECRET" | jq -r '.password')

echo "MongoDB credentials retrieved successfully."

echo "Secret Successfully Retrieved"

########################################
# Create Dockerfile
########################################

cat > /opt/mongodb/Dockerfile <<'EOF'
FROM mongo:8.0

RUN apt-get update && \
    apt-get install -y nano vim && \
    mkdir -p /var/log/mongodb && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

RUN cat <<'EOC' >/etc/mongod.conf
storage:
  dbPath: /mongodb-data
  directoryPerDB: true
  wiredTiger:
    engineConfig:
      cacheSizeGB: 8
      journalCompressor: snappy
    collectionConfig:
      blockCompressor: snappy
    indexConfig:
      prefixCompression: true

systemLog:
  destination: file
  path: /var/log/mongodb/mongod.log
  logAppend: true
  verbosity: 0

processManagement:
  fork: false

net:
  port: 27017
  bindIp: 0.0.0.0
  maxIncomingConnections: 20000

security:
  authorization: enabled
EOC

EXPOSE 27017

CMD ["mongod","--config","/etc/mongod.conf"]
EOF

########################################
# Create Docker Compose
########################################

cat > /opt/mongodb/docker-compose.yml <<EOF
services:
  mongodb:
    build: .
    container_name: mongodb8

    restart: unless-stopped

    environment:
      MONGO_INITDB_ROOT_USERNAME: ${MONGO_USER}
      MONGO_INITDB_ROOT_PASSWORD: ${MONGO_PASSWORD}

    ports:
      - "27017:27017"

    volumes:
      - /mongodb-data:/mongodb-data
      - /mongodb-data/logs:/var/log/mongodb

    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
EOF

echo "===== Dockerfile ====="

cat /opt/mongodb/Dockerfile

echo "===== docker-compose.yml ====="

cat /opt/mongodb/docker-compose.yml

########################################
# Build MongoDB Image
########################################

cd /opt/mongodb

echo "Building MongoDB Image..."

docker compose build

########################################
# Start MongoDB
########################################

echo "Starting MongoDB..."

docker compose up -d

########################################
# Wait for MongoDB
########################################

echo "Waiting for MongoDB to become ready..."

until docker exec mongodb8 mongosh --quiet --eval "db.adminCommand('ping')" >/dev/null 2>&1
do
    sleep 5
done

echo "MongoDB is ready."

########################################
# Verify Container
########################################

docker ps -a

docker logs mongodb8 --tail 50

########################################
# Verify Authentication
########################################

docker exec mongodb8 mongosh \
    --username "$MONGO_USER" \
    --password "$MONGO_PASSWORD" \
    --authenticationDatabase admin \
    --eval "db.runCommand({connectionStatus:1})"
    
    ########################################
# Verify Storage
########################################

echo "Mounted Volume"

df -h | grep mongodb-data

echo "MongoDB Files"

ls -lah /mongodb-data

########################################
# Finished
########################################

echo "====================================="
echo "MongoDB Installation Completed"
echo "====================================="
