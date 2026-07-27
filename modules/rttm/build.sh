#!/bin/bash
set -e

echo "Building Azure Function package..."

# Clean previous builds
rm -rf .package
rm -f function-app.zip

# Create package directory
mkdir .package

# Copy function files
cp -r * .package/ 2>/dev/null || true
cd .package

# Remove build artifacts
rm -rf .package function-app.zip build.sh 2>/dev/null || true

# Install dependencies to package
pip install --target . -r requirements.txt

# Create zip package
zip -r ../function-app.zip . -x "*.pyc" "*/__pycache__/*"

cd ..
rm -rf .package

echo "Package created: function-app.zip"