
#!/bin/bash

# INFO1112 Assignment 2
# TCP server development

set -u

echo "Starting INFO1112 server..."

echo "Network interfaces:"
ifconfig

echo "Listening TCP ports:"
ss -ltn

echo "Server setup information displayed."
