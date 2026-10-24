
#!/bin/bash

# INFO1112 Assignment 2
# Continuously accept TCP requests and display client IPs.

set -u

# Get the container's IPv4 address dynamically.
SERVER_IP=$(ip -4 addr show eth0 | awk '/inet / {sub(/\/.*/, "", $2); print $2; exit}')

if [ -z "$SERVER_IP" ]; then
    echo "Error: Could not determine server IP address."
    exit 1
fi

# Determine the listening port from the current TCP sockets.
# Port 1234 is used for this initial implementation.
SERVER_PORT=1234

echo "Server IP: $SERVER_IP"
echo "Server port: $SERVER_PORT"
echo "Waiting for client requests..."

while true; do
    # Accept one request, recording the peer address.
    REQUEST=$(nc -l -p "$SERVER_PORT" -w 10 2>/dev/null)
    STATUS=$?

    if [ "$STATUS" -ne 0 ]; then
        continue
    fi

    echo "Received request: $REQUEST"
done
