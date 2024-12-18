#!/bin/bash

set -e

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}Starting WhatsApp Bot Deployment...${NC}"

# Check if running with sudo
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run as root or with sudo${NC}"
    exit 1
fi

# Check for required dependencies
for cmd in docker docker-compose redis-cli curl jq; do
    if ! command -v $cmd &> /dev/null; then
        echo -e "${RED}$cmd is required but not installed. Installing...${NC}"
        apt-get update && apt-get install -y $cmd
    fi
done

# Load environment variables
if [ -f .env ]; then
    source .env
else
    echo -e "${RED}.env file not found. Please create one from .env.example${NC}"
    exit 1
fi

# Build and start services
echo -e "${GREEN}Building and starting services...${NC}"
docker-compose build whatsapp
docker-compose up -d redis whatsapp

# Wait for services to be ready
echo -e "${GREEN}Waiting for services to be ready...${NC}"
sleep 5

# Check Redis connection
if ! redis-cli ping > /dev/null; then
    echo -e "${RED}Redis connection failed${NC}"
    exit 1
fi

# Check WhatsApp service health
if ! curl -s "http://localhost:${WHATSAPP_PORT:-3000}/health" > /dev/null; then
    echo -e "${RED}WhatsApp service health check failed${NC}"
    exit 1
fi

echo -e "${GREEN}WhatsApp Bot deployment completed successfully!${NC}"
echo -e "${GREEN}Service is running on port ${WHATSAPP_PORT:-3000}${NC}"
