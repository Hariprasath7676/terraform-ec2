#!/bin/bash

set -e

exec > /var/log/userdata.log 2>&1

echo "Starting PostgreSQL installation..."

sleep 60

#####################################
# Variables from Terraform
#####################################

#APP_USERNAME="${app_username}"

#APP_PASSWORD="${app_password}"

#APP_DATABASE="${app_database}"

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

mkfs.ext4 -F ${DISK}p1

#####################################
# Mount
#####################################

mkdir -p /postgres_data

UUID=$(blkid -s UUID -o value ${DISK}p1)

echo "Filesystem UUID: $UUID"

grep -q "$UUID" /etc/fstab || \
echo "UUID=${UUID} /postgres_data ext4 defaults,nofail 0 2" >> /etc/fstab

mount -a

#####################################
# Directories
#####################################

mkdir -p /postgres_data/data

mkdir -p /postgres_data/logs

# PostgreSQL container runs as UID:GID 999:999
chown -R 999:999 /postgres_data/data
chown -R 999:999 /postgres_data/logs

chmod 700 /postgres_data/data
chmod 755 /postgres_data/logs

mkdir -p /opt/postgres

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
# Generate Dockerfile
#####################################

cat > /opt/postgres/Dockerfile << 'EOF'
#FROM postgres:18

#RUN sed -i 's/local   all             all                                     trust/local   all             all                                     scram-sha-256/' /usr/share/postgresql/18/pg_hba.conf.sample

#ENTRYPOINT ["docker-entrypoint.sh"]

#CMD ["postgres",
#     "-c","listen_addresses=*",
 #    "-c","logging_collector=on",
  #   "-c","log_directory=/var/log/postgresql",
   #  "-c","log_filename=postgresql.log",
    # "-c","password_encryption=scram-sha-256"]
FROM postgres:18

RUN sed -i 's/local   all             all                                     trust/local   all             all                                     scram-sha-256/' /usr/share/postgresql/18/pg_hba.conf.sample

ENTRYPOINT ["docker-entrypoint.sh"]

CMD ["postgres","-c","listen_addresses=*","-c","logging_collector=on","-c","log_directory=/var/log/postgresql","-c","log_filename=postgresql.log","-c","password_encryption=scram-sha-256"]


EOF

#####################################
# Generate docker-compose.yml
#####################################

cat > /opt/postgres/docker-compose.yml << EOF
services:
  postgres-service:
    build: .
    container_name: postgres-service
    restart: always

    environment:
     POSTGRES_USER: temporal_admin
     POSTGRES_PASSWORD: newpassword
     POSTGRES_DB: temporal_metadata
     POSTGRES_INITDB_ARGS: --auth-local=scram-sha-256 --auth-host=scram-sha-256

    volumes:
      - /postgres_data/data:/var/lib/postgresql
      - /postgres_data/logs:/var/log/postgresql

    ports:
      - "5432:5432"
EOF

#####################################
# Build PostgreSQL Image
#####################################

cd /opt/postgres

docker compose build

#####################################
# Start PostgreSQL
#####################################

docker compose up -d

#####################################
# Wait for Startup
#####################################

sleep 30

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

df -h | grep postgres

echo ""
echo "==========================================="
echo "Mount"
echo "==========================================="

mount | grep postgres

echo ""
echo "==========================================="
echo "fstab"
echo "==========================================="

cat /etc/fstab

echo ""
echo "==========================================="
echo "Container Logs"
echo "==========================================="

docker logs postgres-service --tail 50

echo ""
echo "==========================================="
echo "PostgreSQL Installation Completed"
echo "==========================================="
