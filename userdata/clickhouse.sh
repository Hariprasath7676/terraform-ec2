#!/bin/bash
set -euxo pipefail

# ==========================================
# Install required packages
# ==========================================
apt-get update
apt-get install -y \
    curl \
    wget \
    unzip \
    jq \
    ca-certificates \
    gnupg \
    lsb-release \
    parted
    
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip -q awscliv2.zip
./aws/install

# ==========================================
# Detect EBS volume
# ==========================================
DISK=""

for d in /dev/nvme1n1 /dev/xvdf /dev/sdf; do
    if [ -b "$d" ]; then
        DISK="$d"
        break
    fi
done

if [ -z "$DISK" ]; then
    echo "No data disk found"
    exit 1
fi

echo "Using disk: $DISK"

# ==========================================
# Create partition (if missing)
# ==========================================
if ! lsblk -no NAME "${DISK}" | grep -q "^$(basename ${DISK})p1$"; then
    parted -s "$DISK" mklabel gpt
    parted -s "$DISK" mkpart primary ext4 0% 100%
    partprobe "$DISK"
    sleep 5
fi

PARTITION="${DISK}p1"

# Handle Xen devices (/dev/xvdf1)
if [ ! -b "$PARTITION" ]; then
    PARTITION="${DISK}1"
fi

# ==========================================
# Format filesystem
# ==========================================
if ! blkid "$PARTITION" | grep -q 'TYPE="ext4"'; then
    mkfs.ext4 -F "$PARTITION"
fi

# ==========================================
# Mount ClickHouse data directory
# ==========================================
mkdir -p /data/clickhouse

UUID=$(blkid -s UUID -o value "$PARTITION")

grep -q "$UUID" /etc/fstab || \
echo "UUID=$UUID /data/clickhouse ext4 defaults,nofail 0 2" >> /etc/fstab

mount -a

# Verify mount
df -h

# ==========================================
# Install Docker
# ==========================================
curl -fsSL https://get.docker.com | sh

systemctl enable docker
systemctl start docker

# ==========================================
# Install Docker Compose Plugin
# ==========================================
apt-get install -y docker-compose-plugin

# ==========================================
# Verify installation
# ==========================================
docker --version
docker compose version

# ==========================================
# Create directories
# ==========================================
mkdir -p /root/docker
mkdir -p /root/clickhouse-configurations/users.d

aws s3 cp s3://unosecur-terraform-for-dataservers/clickhouse-configurations/config.xml  \
    /root/clickhouse-configurations/config.xml


SECRET_NAME="clickhouse-users"
AWS_REGION="eu-central-1"

SECRET_JSON=$(aws secretsmanager get-secret-value \
    --secret-id "$SECRET_NAME" \
    --region "$AWS_REGION" \
    --query SecretString \
    --output text)

DEFAULT_PASSWORD=$(echo "$SECRET_JSON" | jq -r '.default_password')
ADMIN_PASSWORD=$(echo "$SECRET_JSON" | jq -r '.admin_password')

cat > /root/docker/Dockerfile <<'EOF'
FROM clickhouse/clickhouse-server:latest

USER root
RUN apt-get update && apt-get install -y nano
USER clickhouse
EOF

cat > /root/docker/docker-compose.yaml <<'EOF'
version: '3.8'

services:
  clickhouse:
    image: clickhouse/clickhouse-server:latest
    container_name: clickhouse-server
    restart: unless-stopped

    ulimits:
      nofile:
        soft: 262144
        hard: 262144

    ports:
      - "8123:8123"
      - "9000:9000"

    volumes:
      - /data/clickhouse:/var/lib/clickhouse
      - /root/clickhouse-configurations/config.xml:/etc/clickhouse-server/config.xml
      - /root/clickhouse-configurations/users.xml:/etc/clickhouse-server/users.xml
      - /root/clickhouse-configurations/users.d/default-user.xml:/etc/clickhouse-server/users.d/default-user.xml
EOF

cat > /root/clickhouse-configurations/users.xml <<EOF
<clickhouse>

    <profiles>
        <default/>
    </profiles>

    <users>

        <default>
            <password>${DEFAULT_PASSWORD}</password>
            <networks>
                <ip>::/0</ip>
            </networks>
            <profile>default</profile>
            <quota>default</quota>
            <access_management>1</access_management>
            <named_collection_control>1</named_collection_control>
        </default>

        <admin>
            <password>${ADMIN_PASSWORD}</password>
            <networks>
                <ip>::/0</ip>
            </networks>
            <profile>default</profile>
            <quota>default</quota>
            <access_management>1</access_management>
            <named_collection_control>1</named_collection_control>
        </admin>

    </users>

    <quotas>
        <default>
            <interval>
                <duration>3600</duration>
                <queries>0</queries>
                <errors>0</errors>
                <result_rows>0</result_rows>
                <read_rows>0</read_rows>
                <execution_time>0</execution_time>
            </interval>
        </default>
    </quotas>

</clickhouse>
EOF

cat > /root/clickhouse-configurations/users.d/default-user.xml <<'EOF'
<clickhouse>
  <users>
    <default>
      <networks>
        <ip>::/0</ip>
      </networks>
    </default>
  </users>
</clickhouse>
EOF

# Go to docker directory
cd /root/docker

# Start ClickHouse
docker compose up -d

# Wait for the container
until docker exec clickhouse-server clickhouse-client --query "SELECT 1" >/dev/null 2>&1
do
    sleep 2
done


