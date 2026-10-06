#!/bin/bash
# Start MerlinPlatform with its Grid token, read from SSM at each start rather than kept on disk.
# The settings that are not secret are in /etc/merlin/platform.env (systemd's EnvironmentFile).
set -euo pipefail

param() {
    aws ssm get-parameter --region us-east-1 --with-decryption \
        --name "/merlin/mutinynet/platform/$1" --query Parameter.Value --output text
}
GRID_CLIENT_ID="$(param grid-client-id)"
GRID_CLIENT_SECRET="$(param grid-client-secret)"
export GRID_CLIENT_ID GRID_CLIENT_SECRET

# Loopback: Caddy is the only way in, on :8443.
exec /usr/local/bin/merlin-platform --bind 127.0.0.1 --port 7200
