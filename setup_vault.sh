#!/bin/bash

$WORDPRESS_DB_NAME
$TG_PROXY_SECRET
$MARIADB_ROOT_PASSWORD

# Enable debug output
set -x

# Check required environment variables
if [[ -z "$MARIADB_ROOT_PASSWORD" || -z "$TG_PROXY_SECRET" ]]; then
    echo "Error: MARIADB_ROOT_PASSWORD and TG_PROXY_SECRET must be set in the environment." >&2
    exit 1
fi

# Remove Vault data folder
echo "Removing Vault data folder..."
rm -rf vault/data

# Create necessary directories
mkdir -p vault/config vault/policies vault/data vault/logs

# Create Vault configuration file
cat >vault/config/vault.hcl <<EOF
storage "file" {
  path = "/vault/data"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = 1
}

ui = true

api_addr = "http://127.0.0.1:8200"
EOF

# Remove old containers and volumes
echo "Removing existing containers and volumes..."
docker compose -f docker-compose.yaml down wp-db -v
docker compose -f compose.vault.yaml down -v

# Recreate and start containers
echo "Creating and starting containers..."
docker compose -f compose.vault.yaml up -d
sleep 30
# Export Vault server address
export VAULT_ADDR="http://127.0.0.1:8200"

# Initialize Vault and export init output to file
echo "Initializing Vault..."

docker exec -e VAULT_ADDR=$VAULT_ADDR vault chown -R vault:vault /vault
docker exec -e VAULT_ADDR=$VAULT_ADDR vault vault operator init -key-shares=5 -key-threshold=3 -format=json >vault_init.json

# Parse init output
echo "Parsing initialization output..."
export ROOT_TOKEN=$(jq -r '.root_token' vault_init.json)
export UNSEAL_KEY_1=$(jq -r '.unseal_keys_b64[0]' vault_init.json)
export UNSEAL_KEY_2=$(jq -r '.unseal_keys_b64[1]' vault_init.json)
export UNSEAL_KEY_3=$(jq -r '.unseal_keys_b64[2]' vault_init.json)

# Unseal Vault
echo "Unsealing Vault..."
docker exec -e VAULT_ADDR=$VAULT_ADDR vault vault operator unseal "$UNSEAL_KEY_1"
docker exec -e VAULT_ADDR=$VAULT_ADDR vault vault operator unseal "$UNSEAL_KEY_2"
docker exec -e VAULT_ADDR=$VAULT_ADDR vault vault operator unseal "$UNSEAL_KEY_3"

# Log in to Vault
echo "Logging in to Vault..."
docker exec -e VAULT_ADDR=$VAULT_ADDR vault vault login "$ROOT_TOKEN"

# Enable KV secrets engine
echo "Enabling KV secrets engine..."
docker exec -e VAULT_ADDR=$VAULT_ADDR vault vault secrets enable -path=secret kv-v2 || true

# Define the list of services
export services=(wp-db wp-app tg-proxy)

# Create policies
echo "Creating policies..."
for service in "${services[@]}"; do
    cat <<EOF >vault/policies/${service}-policy.hcl
path "secret/data/${service}" {
  capabilities = ["read"]
}
EOF
    docker exec -e VAULT_ADDR=$VAULT_ADDR -i vault vault policy write ${service}-policy /vault/policies/${service}-policy.hcl
done

# Add database policy for wp-app
cat <<EOF >vault/policies/wp-app-db-policy.hcl
path "database/creds/wp-app" {
  capabilities = ["read"]
}
EOF
docker exec -e VAULT_ADDR=$VAULT_ADDR -i vault vault policy write wp-app-db-policy /vault/policies/wp-app-db-policy.hcl

# Enable AppRole auth method
echo "Enabling AppRole auth method..."
docker exec -e VAULT_ADDR=$VAULT_ADDR vault vault auth enable approle || true

# Create AppRoles and get RoleIDs and SecretIDs
echo "Creating AppRoles and getting RoleIDs and SecretIDs..."
for service in "${services[@]}"; do
    export policies="${service}-policy"
    if [ "$service" == "wp-app" ]; then
        policies="${policies},wp-app-db-policy"
    fi
    docker exec -e VAULT_ADDR=$VAULT_ADDR vault vault write auth/approle/role/${service}-role \
        secret_id_ttl=0 \
        token_num_uses=0 \
        token_ttl=0 \
        token_max_ttl=0 \
        secret_id_num_uses=0 \
        policies=${policies}

    export ROLE_ID=$(docker exec -e VAULT_ADDR=$VAULT_ADDR vault vault read -field=role_id auth/approle/role/${service}-role/role-id)
    export SECRET_ID=$(docker exec -e VAULT_ADDR=$VAULT_ADDR vault vault write -f -field=secret_id auth/approle/role/${service}-role/secret-id)

    export service_upper=$(echo ${service^^} | tr '-' '_')
    echo "${service_upper}_ROLE_ID=$ROLE_ID" >>env/.env.vault
    echo "${service_upper}_SECRET_ID=$SECRET_ID" >>env/.env.vault
done

# Store secrets
echo "Storing secrets..."
docker exec -e VAULT_ADDR=$VAULT_ADDR vault vault kv put secret/wp-db \
    MARIADB_ROOT_PASSWORD="$MARIADB_ROOT_PASSWORD"

docker exec -e VAULT_ADDR=$VAULT_ADDR vault vault kv put secret/tg-proxy \
    SECRET="$TG_PROXY_SECRET"

sleep 5

docker compose -f docker-compose.yaml up wp-db -d

# Wait for wp-db to be ready
echo "Waiting for wp-db to be ready..."
while ! docker compose -f docker-compose.yaml exec -T wp-db mysqladmin ping -h localhost --silent; do
    echo "wp-db is not ready yet. Waiting..."
    sleep 5
done
echo "wp-db is ready."

# Enable database secrets engine
echo "Enabling database secrets engine..."
docker exec -e VAULT_ADDR=$VAULT_ADDR vault vault secrets enable database || true

sleep 30
# Configure the MariaDB connection
echo "Configuring MariaDB connection..."
docker exec -e VAULT_ADDR=$VAULT_ADDR vault vault write database/config/mariadb \
    plugin_name=mysql-database-plugin \
    connection_url="{{username}}:{{password}}@tcp(wp-db:3306)/" \
    allowed_roles="wp-app" \
    username="root" \
    password="$MARIADB_ROOT_PASSWORD"

# Create a role for generating dynamic secrets
echo "Creating role for dynamic secrets..."
docker exec -e VAULT_ADDR=$VAULT_ADDR vault vault write database/roles/wp-app \
    db_name=mariadb \
    creation_statements="CREATE USER '{{name}}'@'%' IDENTIFIED BY '{{password}}'; GRANT ALL PRIVILEGES ON \`wordpress\`.* TO '{{name}}'@'%';" \
    default_ttl="24h" \
    max_ttl="24h"

# Update variable names in .env.vault
sed -i 's/^\([^=]*\)-/\1_/' env/.env.vault

echo "Vault setup complete!"

# Disable debug output
set +x
