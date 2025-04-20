#!/bin/bash
set -e

# This script builds the sqlite-server with extension loading for MacOS ARM (Apple Silicon)
# by using a locally patched version of go-sqlite3

# Exit if not on MacOS ARM
if [[ "$(uname)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
  echo "This script is specifically for MacOS ARM (Apple Silicon)"
  exit 1
fi

echo "Building sqlite-server for MacOS ARM with SQLite extension loading support..."

# Check if the locally patched go-sqlite3 exists
if [ ! -d "/Users/jonudell/go-sqlite3" ]; then
  echo "Error: Patched go-sqlite3 not found at /Users/jonudell/go-sqlite3"
  echo "Please clone and patch the go-sqlite3 repository first"
  exit 1
fi

# Download Steampipe SQLite extension for GitHub if not already present
if [ ! -f steampipe_sqlite_github.so ]; then
  echo "Downloading Steampipe SQLite extension for GitHub..."
  EXTENSION_URL="https://github.com/turbot/steampipe-plugin-github/releases/download/v1.2.0/steampipe_sqlite_github.darwin_arm64.tar.gz"
  echo "Downloading extension from ${EXTENSION_URL}"
  
  curl -L "${EXTENSION_URL}" > ext.tar.gz
  tar xvf ext.tar.gz
  
  # Ensure proper permissions
  chmod 755 steampipe_sqlite_github.so
  
  # Verify file type
  echo "Extension file type:"
  file steampipe_sqlite_github.so
fi

# Build the server with required flags and tags to enable extension loading
echo "Building sqlite-server with extension loading support..."
rm -f sqlite-server-macos-arm

# Set up the environment for go-sqlite3 with extension loading
CGO_ENABLED=1 \
CGO_CFLAGS="-DSQLITE_ENABLE_LOAD_EXTENSION -DSQLITE_ALLOW_LOAD_EXTENSION" \
go build -tags "sqlite3_load_extension" -v -o sqlite-server-macos-arm sqlite-server.go

# Verify the binary was built and check its dependencies
echo "Build complete. Checking binary:"
ls -la sqlite-server-macos-arm

# macOS uses otool instead of ldd to check dependencies
otool -L sqlite-server-macos-arm

# Make sure extension is executable
chmod 755 steampipe_sqlite_github.so

echo "Build process complete!"
echo ""
echo "To run the server:"
echo "./sqlite-server-macos-arm -port 8080"
echo ""
echo "The server uses a locally patched version of go-sqlite3 to enable extension loading on MacOS ARM."