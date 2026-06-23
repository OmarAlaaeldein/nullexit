#!/bin/bash

# Generate a random high-numbered ephemeral port between 1024 and 65535
export RANDOM_PORT=$((1024 + RANDOM % 64511))

echo "🔒 Generating a random internal WireGuard Port: $RANDOM_PORT"
echo "🚀 Starting Docker Gateway..."

# Launch the gateway with the randomized port
docker compose up -d

echo "✅ Gateway is fully online and randomized."
