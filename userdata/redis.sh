#!/bin/bash

set -e

exec > /var/log/userdata.log 2>&1

echo "Starting Redis installation..."

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
# Mount Redis Data
#####################################

mkdir -p /redis-data

UUID=$(blkid -s UUID -o value ${DISK}p1)

grep -q "$UUID" /etc/fstab || \
echo "UUID=${UUID} /redis-data ext4 defaults,nofail 0 2" >> /etc/fstab

mount -a

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
# Directories
#####################################

mkdir -p /redis-logs
mkdir -p /opt/redis

chown -R 999:999 /redis-data
chown -R 999:999 /redis-logs

#####################################
# redis.conf
#####################################

cat > /opt/redis/redis.conf << 'EOF'
bind 0.0.0.0
protected-mode no
port 6379

tcp-backlog 511
timeout 0
tcp-keepalive 300

save 900 1
save 300 10
save 60 10000

stop-writes-on-bgsave-error yes
rdbcompression yes
rdbchecksum yes

dir /data

replica-serve-stale-data yes

lazyfree-lazy-eviction yes
lazyfree-lazy-expire yes
lazyfree-lazy-server-del yes
replica-lazy-flush no
lazyfree-lazy-user-del no

hz 50
dynamic-hz yes

aof-rewrite-incremental-fsync yes
rdb-save-incremental-fsync yes

jemalloc-bg-thread yes

logfile "/var/log/redis/redis.log"
EOF

#####################################
# entrypoint.sh
#####################################

cat > /opt/redis/entrypoint.sh << 'EOF'
#!/bin/bash

mkdir -p /var/log/redis

touch /var/log/redis/redis.log

chown -R redis:redis /var/log/redis
chown -R redis:redis /data

redis-server /etc/redis-ext.conf
EOF

chmod +x /opt/redis/entrypoint.sh

#####################################
# docker-compose.yml
#####################################

cat > /opt/redis/docker-compose.yml << 'EOF'
services:
  redis:
    image: redis:6.0.16
    container_name: redis-server
    restart: always
    ports:
      - "6379:6379"
    volumes:
      - /redis-data:/data
      - /redis-logs:/var/log/redis
      - /opt/redis/redis.conf:/etc/redis-ext.conf
      - /opt/redis/entrypoint.sh:/root/entrypoint.sh
    command: ["bash","/root/entrypoint.sh"]
EOF

#####################################
# Start Redis
#####################################

cd /opt/redis

docker compose up -d

echo "Redis installation completed successfully"
