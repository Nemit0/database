#!/bin/bash
# run.sh - Pull latest code, create necessary folders, rebuild and start containers

set -e  # Exit on any error

echo "Stopping and removing any running containers..."
docker compose down

# Define the required folders
required_folders=(
    "elasticsearch/data"
    "mongodb/config"
    "mongodb/data"
    "mongodb/initdb"
    "mysql/conf.d"
    "mysql/data"    
    "mysql/initdb"
)

# Ensure required folders exist
echo "Checking for required folders..."
for folder in "${required_folders[@]}"; do
    if [ ! -d "$folder" ]; then
        echo "Creating missing folder: $folder"
        mkdir -p "$folder"
    fi
done

# Set the branch to pull
branch="main"

echo "Pulling latest code from '$branch'..."
git pull origin "$branch"

echo "Rebuilding and starting Docker containers..."
docker compose up --build -d

echo "✅ Deployment complete."
