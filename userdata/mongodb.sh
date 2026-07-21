#!/bin/bash

set -e

exec > /var/log/userdata.log 2>&1

echo "Starting MongoDB installation..."

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
# Partition
#####################################

if ! lsblk ${DISK}p1 >/dev/null 2>&1; then

    echo -e "n\np\n1\n\n\nw" | fdisk $DISK

    partprobe $DISK

    udevadm settle

    sleep 10

fi

#####################################
# Format
#####################################

if ! blkid ${DISK}p1 >/dev/null 2>&1; then

    echo "Formatting ${DISK}p1..."

    mkfs.ext4 -F ${DISK}p1

else

    echo "Filesystem already exists. Skipping format."

fi

#####################################
# Mount
#####################################

mkdir -p /mongodb-data

UUID=$(blkid -s UUID -o value ${DISK}p1)

echo "Filesystem UUID: $UUID"

grep -q "$UUID" /etc/fstab || \
echo "UUID=${UUID} /mongodb-data ext4 defaults,nofail 0 2" >> /etc/fstab

mount -a

#####################################
# Directories
#####################################

mkdir -p /mongodb-data/logs

mkdir -p /opt/mongodb

#####################################
# Permissions
#####################################

chown -R 999:999 /mongodb-data

chmod -R 755 /mongodb-data

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
| tee /etc/apt/sources.list.d/docker.list >/dev/null

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
# Install AWS CLI and jq
#####################################

apt-get update

apt-get install -y unzip curl jq

cd /tmp

curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip

unzip -q awscliv2.zip

./aws/install

aws --version

jq --version

docker --version

docker compose version

#####################################
# Read MongoDB Secret
#####################################

SECRET=$(aws secretsmanager get-secret-value \
  --secret-id terraform-mongodb \
  --query SecretString \
  --output text)

if [ -z "$SECRET" ] || [ "$SECRET" = "null" ]; then

    echo "ERROR: Failed to retrieve MongoDB secret."

    exit 1

fi

MONGO_USER=$(echo "$SECRET" | jq -r '.username')

MONGO_PASSWORD=$(echo "$SECRET" | jq -r '.password')

if [ -z "$MONGO_USER" ] || [ "$MONGO_USER" = "null" ] || \
   [ -z "$MONGO_PASSWORD" ] || [ "$MONGO_PASSWORD" = "null" ]; then

    echo "ERROR: Invalid MongoDB credentials."

    exit 1

fi

echo "MongoDB credentials retrieved successfully."

#####################################
# Generate Dockerfile
#####################################

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

echo ""
echo "==========================================="
echo "Dockerfile"
echo "==========================================="

cat /opt/mongodb/Dockerfile

#####################################
# Generate docker-compose.yml
#####################################

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

echo ""
echo "==========================================="
echo "Docker Compose"
echo "==========================================="

cat /opt/mongodb/docker-compose.yml

#####################################
# Build MongoDB Image
#####################################

cd /opt/mongodb

echo "Building MongoDB image..."

docker compose build

#####################################
# Start MongoDB
#####################################

echo "Starting MongoDB..."

docker compose up -d

#####################################
# Wait for MongoDB Startup
#####################################

echo "Waiting for MongoDB to become ready..."

until docker exec mongodb8 mongosh --quiet --eval "db.adminCommand('ping')" >/dev/null 2>&1
do
    sleep 5
done

echo "MongoDB is ready."

#####################################
# Verify Authentication
#####################################

docker exec mongodb8 mongosh \
    --username "$MONGO_USER" \
    --password "$MONGO_PASSWORD" \
    --authenticationDatabase admin \
    --eval "db.runCommand({connectionStatus:1})"
  
#####################################
# Verification
#####################################

echo ""
echo "==========================================="
echo "Docker Containers"
echo "==========================================="

docker ps -a

echo ""
echo "==========================================="
echo "Mounted Filesystem"
echo "==========================================="

df -h | grep mongodb

echo ""
echo "==========================================="
echo "Mount"
echo "==========================================="

mount | grep mongodb

echo ""
echo "==========================================="
echo "fstab"
echo "==========================================="

cat /etc/fstab

echo ""
echo "==========================================="
echo "Container Logs"
echo "==========================================="

docker logs mongodb8 --tail 50

echo ""
echo "==========================================="
echo "MongoDB Data Directory"
echo "==========================================="

ls -lah /mongodb-data

echo ""
echo "==========================================="
echo "MongoDB Log Directory"
echo "==========================================="

ls -lah /mongodb-data/logs

echo ""
echo "==========================================="
echo "MongoDB Installation Completed"
echo "==========================================="
