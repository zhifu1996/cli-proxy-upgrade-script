#!/bin/bash
#
# CLIProxyAPI Upgrade Script
# Usage: ./upgrade.sh
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Get script directory (project root)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Backup directory
BACKUP_DIR="$SCRIPT_DIR/backups"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
BACKUP_PATH="$BACKUP_DIR/backup_$TIMESTAMP"

# API port for usage statistics
API_PORT="${CLI_PROXY_API_PORT:-8317}"

# Management API authentication
# Try to get password from environment or .env file
if [ -z "$MANAGEMENT_PASSWORD" ] && [ -f ".env" ]; then
    MANAGEMENT_PASSWORD=$(grep -E "^MANAGEMENT_PASSWORD=" .env 2>/dev/null | cut -d'=' -f2- | tr -d '"' | tr -d "'")
fi

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}   CLIProxyAPI Upgrade Script${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Step 1: Create backup
echo -e "${YELLOW}[1/6] Creating backup...${NC}"
mkdir -p "$BACKUP_PATH"

# Backup config.yaml if exists
if [ -f "config.yaml" ]; then
    cp config.yaml "$BACKUP_PATH/"
    echo "  - config.yaml backed up"
else
    echo "  - config.yaml not found, skipping"
fi

# Backup .env if exists
if [ -f ".env" ]; then
    cp .env "$BACKUP_PATH/"
    echo "  - .env backed up"
else
    echo "  - .env not found, skipping"
fi

# Backup auths directory if exists and not empty
if [ -d "auths" ] && [ "$(ls -A auths 2>/dev/null | grep -v .gitkeep)" ]; then
    cp -r auths "$BACKUP_PATH/"
    echo "  - auths/ directory backed up"
else
    echo "  - auths/ empty or not found, skipping"
fi

# Backup logs directory if exists (optional, can be large)
# Uncomment if you want to backup logs
# if [ -d "logs" ]; then
#     cp -r logs "$BACKUP_PATH/"
#     echo "  - logs/ directory backed up"
# fi

echo -e "${GREEN}  Backup saved to: $BACKUP_PATH${NC}"
echo ""

# Step 2: Export usage statistics (before stopping)
echo -e "${YELLOW}[2/6] Exporting usage statistics...${NC}"
USAGE_BACKUP="$BACKUP_PATH/usage_stats.json"

if [ -z "$MANAGEMENT_PASSWORD" ]; then
    echo "  - MANAGEMENT_PASSWORD not set, skipping usage backup"
    echo "  - Set MANAGEMENT_PASSWORD in .env or environment to enable usage backup"
    USAGE_BACKUP=""
elif curl -sf -H "Authorization: Bearer $MANAGEMENT_PASSWORD" \
    "http://localhost:$API_PORT/v0/management/usage/export" -o "$USAGE_BACKUP" 2>/dev/null; then
    echo -e "${GREEN}  Usage statistics exported to: $USAGE_BACKUP${NC}"
else
    echo "  - Service not running or export failed, skipping"
    USAGE_BACKUP=""
fi
echo ""

# Step 3: Stop containers
echo -e "${YELLOW}[3/6] Stopping containers...${NC}"
docker compose down || docker-compose down
echo ""

# Step 4: Pull latest code
echo -e "${YELLOW}[4/6] Pulling latest code from git...${NC}"
git fetch origin
git pull origin main || git pull origin master
echo ""

# Step 5: Pull latest image
echo -e "${YELLOW}[5/6] Pulling latest Docker image...${NC}"
docker compose pull || docker-compose pull
echo ""

# Step 6: Start containers
echo -e "${YELLOW}[6/6] Starting containers...${NC}"
docker compose up -d || docker-compose up -d
echo ""

# Import usage statistics (after starting)
if [ -n "$USAGE_BACKUP" ] && [ -f "$USAGE_BACKUP" ]; then
    echo -e "${YELLOW}Restoring usage statistics...${NC}"
    # Wait for service to be ready
    echo "  Waiting for service to start..."
    sleep 5

    # Retry import up to 3 times
    for i in 1 2 3; do
        if curl -sf -X POST \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer $MANAGEMENT_PASSWORD" \
            -d @"$USAGE_BACKUP" \
            "http://localhost:$API_PORT/v0/management/usage/import" >/dev/null 2>&1; then
            echo -e "${GREEN}  Usage statistics restored successfully${NC}"
            break
        else
            if [ $i -lt 3 ]; then
                echo "  - Attempt $i failed, retrying in 3 seconds..."
                sleep 3
            else
                echo -e "${RED}  Failed to restore usage statistics after 3 attempts${NC}"
                echo "  You can manually import later with:"
                echo "    curl -X POST -H 'Content-Type: application/json' -H 'Authorization: Bearer \$MANAGEMENT_PASSWORD' -d @$USAGE_BACKUP http://localhost:$API_PORT/v0/management/usage/import"
            fi
        fi
    done
    echo ""
fi

# Show status
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}   Upgrade completed!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "Backup location: $BACKUP_PATH"
echo ""
echo "Container status:"
docker compose ps || docker-compose ps

# Cleanup old backups (keep last 10)
echo ""
echo -e "${YELLOW}Cleaning up old backups (keeping last 10)...${NC}"
cd "$BACKUP_DIR"
ls -dt backup_* 2>/dev/null | tail -n +11 | xargs -r rm -rf
echo "Done."
