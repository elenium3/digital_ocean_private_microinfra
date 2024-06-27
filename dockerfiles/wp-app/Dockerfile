# Stage 1: Get the Vault binary from the official HashiCorp image
FROM hashicorp/vault:latest AS vault

# Stage 2: Build the final WordPress image
FROM wordpress:php8.3-apache

# Copy the Vault binary from the previous stage
COPY --from=vault /bin/vault /usr/local/bin/

# Install jq for JSON parsing
RUN apt update && apt install jq -y
USER www-data
RUN cp -r /usr/src/wordpress/* /var/www/html/

COPY ./vault-wordpress-plugin.php /var/www/html/wp-content/plugins/
COPY ./wp-config.php /var/www/html/
# Switch to a non-root user
