#!/bin/bash

# Install Docker
echo "Installing Docker..."
sudo apt-get update
sudo apt-get install -y \
    ca-certificates \
    curl \
    gnupg \
    lsb-release

sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
sudo apt-get install -y libxcb-dri3-0 libgbm1 libdrm2 xdg-utils libnotify4 libnss3

# Install perf tools
echo "Installing performance monitoring tools..."
sudo apt-get update
sudo apt-get install -y linux-tools-common linux-tools-generic linux-tools-`uname -r`

# Set up permissions for perf
echo "Setting up permissions for performance monitoring..."
echo 0 | sudo tee /proc/sys/kernel/kptr_restrict
echo 0 | sudo tee /proc/sys/kernel/perf_event_paranoid

# Add persistent settings for perf permissions
sudo bash -c 'cat >> /etc/sysctl.d/99-perf.conf << EOF
kernel.kptr_restrict = 0
kernel.perf_event_paranoid = 0
EOF'

# Enable docker buildx for multi-architecture builds
echo "Setting up Docker buildx..."
docker run --rm --privileged multiarch/qemu-user-static --reset -p yes
docker buildx rm host-builder || true
docker buildx create --use --name host-builder --buildkitd-flags '--allow-insecure-entitlement network.host'
docker buildx use host-builder
docker buildx inspect --bootstrap

# Pull necessary base images
echo "Pulling base images..."
docker pull cloudsuite/spark:3.3.2

# Data Serving
echo "Pulling Data Serving images..."
docker pull cloudsuite/data-serving:server
docker pull cloudsuite/data-serving:client

# Data Serving Relational
echo "Pulling Data Serving Relational images..."
docker pull cloudsuite/data-serving-relational:server
docker pull cloudsuite/data-serving-relational:client

# Data Caching
echo "Pulling Data Caching images..."
docker pull cloudsuite/data-caching:server
docker pull cloudsuite/data-caching:client

# Graph Analytics
echo "Pulling Graph Analytics images..."
docker pull cloudsuite/graph-analytics
docker pull cloudsuite/twitter-dataset-graph

# In-Memory Analytics
echo "Pulling In-Memory Analytics images..."
docker pull cloudsuite/in-memory-analytics
docker pull cloudsuite/movielens-dataset

# Media Streaming
echo "Pulling Media Streaming images..."
docker pull cloudsuite/media-streaming:dataset
docker pull cloudsuite/media-streaming:server
docker pull cloudsuite/media-streaming:client

# Web Search
echo "Pulling Web Search images..."
docker pull cloudsuite/web-search:dataset
docker pull cloudsuite/web-search:server
docker pull cloudsuite/web-search:client

# Web Serving
echo "Pulling Web Serving images..."
docker pull cloudsuite/web-serving:db_server
docker pull cloudsuite/web-serving:memcached_server
docker pull cloudsuite/web-serving:web_server
docker pull cloudsuite/web-serving:faban_client

echo "Installation completed!"