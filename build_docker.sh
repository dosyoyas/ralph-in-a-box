#!/bin/bash
set -e

cd "$(dirname "$0")"

echo "=== Building ralph-python ==="
docker build --no-cache -f python/Dockerfile.python -t ralph-python:latest .

echo ""
echo "=== Building ralph-rust ==="
docker build --no-cache -f rust/Dockerfile.rust -t ralph-rust:latest .

echo ""
echo "All images built successfully."
docker images --filter "reference=ralph-*" --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}\t{{.CreatedAt}}"
