#!/bin/bash

APP_USERNAME="${app_username}"
APP_PASSWORD="${app_password}"
APP_DATABASE="${app_database}"

cat >/opt/postgres/.env <<EOF
POSTGRES_USER=$APP_USERNAME
POSTGRES_PASSWORD=$APP_PASSWORD
POSTGRES_DB=$APP_DATABASE
EOF

bash /opt/postgres/postgres-install.sh
