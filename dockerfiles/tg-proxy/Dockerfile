# Stage 1: Get the Vault binary from the official HashiCorp image
FROM hashicorp/vault:latest AS vault

# Stage 2: Final image
FROM telegrammessenger/proxy:latest

# Copy the Vault binary from the previous stage
COPY --from=vault /bin/vault /usr/local/bin/vault