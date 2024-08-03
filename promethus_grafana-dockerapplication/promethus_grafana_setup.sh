#!/bin/bash

# Color variables
RED='\033[0;31m'   # Red colored text
NC='\033[0m'       # Normal text
YELLOW='\033[33m'  # Yellow Color
GREEN='\033[32m'   # Green Color

# Function for error handling
error_exit() {
    echo -e "${RED}Error: $1${NC}" >&2
    exit 1
}

# Function for success message
success_message() {
    echo -e "${GREEN}$1${NC}"
}

# Function for warning message
warning_message() {
    echo -e "${YELLOW}$1${NC}"
}

# Check if script is run as root
if [[ $EUID -ne 0 ]]; then
    error_exit "This script must be run as root"
fi

# Check if Docker is installed
if ! command -v docker &> /dev/null; then
    warning_message "Docker is not installed. Installing Docker..."
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    if [ $? -ne 0 ]; then
        error_exit "Failed to install Docker"
    fi
    success_message "Docker installed successfully"
fi

# Check if Docker Compose is installed
if ! command -v docker-compose &> /dev/null; then
    warning_message "Docker Compose is not installed. Installing Docker Compose..."
    curl -L "https://github.com/docker/compose/releases/download/1.29.2/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
    if [ $? -ne 0 ]; then
        error_exit "Failed to install Docker Compose"
    fi
    success_message "Docker Compose installed successfully"
fi

# Create necessary directories
warning_message "Creating directories..."
mkdir -p /etc/prometheus /var/lib/prometheus /var/lib/grafana || error_exit "Failed to create directories"
success_message "Directories created successfully"

# Fix permissions for the directories
warning_message "Fixing permissions for directories..."
chown -R 472:472 /var/lib/grafana || error_exit "Failed to set permissions for Grafana directory"
chown -R 65534:65534 /var/lib/prometheus || error_exit "Failed to set permissions for Prometheus directory"
success_message "Permissions fixed successfully"

# Create Prometheus configuration file
warning_message "Creating Prometheus configuration file..."
cat > /etc/prometheus/prometheus.yml <<EOT
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']
EOT
if [ $? -ne 0 ]; then
    error_exit "Failed to create Prometheus configuration file"
fi
success_message "Prometheus configuration file created successfully"

# Create Docker Compose file
warning_message "Creating Docker Compose file..."
cat > /etc/prometheus/docker-compose.yml <<EOT
version: '3.7'

services:
  prometheus:
    image: prom/prometheus:latest
    container_name: prometheus
    user: "65534:65534"
    volumes:
      - /etc/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml
      - /var/lib/prometheus:/prometheus
    ports:
      - "9090:9090"
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
      - '--web.console.templates=/etc/prometheus/consoles'
      - '--web.console.libraries=/etc/prometheus/console_libraries'

  grafana:
    image: grafana/grafana:latest
    container_name: grafana
    user: "472:472"
    ports:
      - "3000:3000"
    volumes:
      - /var/lib/grafana:/var/lib/grafana
    environment:
      - GF_SECURITY_ADMIN_USER=admin
      - GF_SECURITY_ADMIN_PASSWORD=admin
    depends_on:
      - prometheus
EOT
if [ $? -ne 0 ]; then
    error_exit "Failed to create Docker Compose file"
fi
success_message "Docker Compose file created successfully"

# Start Prometheus and Grafana using Docker Compose
warning_message "Starting Prometheus and Grafana using Docker Compose..."
cd /etc/prometheus || error_exit "Failed to change directory"
if docker-compose up -d; then
    success_message "Prometheus and Grafana started successfully!"
else
    error_exit "Failed to start Prometheus and Grafana"
fi

success_message "Prometheus is available at 'your_public_ip:9090'"
success_message "Grafana is available at 'your_public_ip:3000' with default login (admin/admin)"
