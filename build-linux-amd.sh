#!/bin/bash

# This script builds the xmlui-test-server with extension loading for Linux AMD64

set -e

go mod tidy

# Create a clean working directory
echo "Creating clean working directory..."
mkdir -p xmlui-test-server-build
cd xmlui-test-server-build

# Download and build SQLite with extension loading enabled
echo "Downloading and building SQLite with extension loading enabled..."
if [ ! -f sqlite-autoconf-3450200.tar.gz ]; then
  wget https://www.sqlite.org/2024/sqlite-autoconf-3450200.tar.gz
fi

if [ ! -d sqlite-autoconf-3450200 ]; then
  tar xzf sqlite-autoconf-3450200.tar.gz
fi

cd sqlite-autoconf-3450200

# Configure and build SQLite with extension loading flags
SQLITE_INSTALL_DIR=$(pwd)/../sqlite-install
if [ ! -d "$SQLITE_INSTALL_DIR" ]; then
  CFLAGS="-DSQLITE_ENABLE_LOAD_EXTENSION=1 -DSQLITE_ALLOW_LOAD_EXTENSION=1" ./configure --prefix=$SQLITE_INSTALL_DIR --disable-shared --enable-static
  make CFLAGS="-DSQLITE_ENABLE_LOAD_EXTENSION=1 -DSQLITE_ALLOW_LOAD_EXTENSION=1" -j4
  make install
fi

# Return to project directory
cd ../../

# Download Steampipe SQLite extension for GitHub
echo "Downloading Steampipe SQLite extension for GitHub..."
if [ ! -f steampipe_sqlite_github.so ]; then
  # Detect OS and architecture
  OS_TYPE=$(uname -s | tr '[:upper:]' '[:lower:]')
  ARCH=$(uname -m)
  if [[ "$ARCH" == "x86_64" ]]; then
    ARCH="amd64"
  elif [[ "$ARCH" == "arm64" || "$ARCH" == "aarch64" ]]; then
    ARCH="arm64"
  fi

  # Print detected environment
  echo "Detected environment: ${OS_TYPE}_${ARCH}"

  EXTENSION_URL="https://github.com/turbot/steampipe-plugin-github/releases/download/v1.2.0/steampipe_sqlite_github.${OS_TYPE}_${ARCH}.tar.gz"
  echo "Downloading extension for ${OS_TYPE}_${ARCH} from ${EXTENSION_URL}"

  curl -L "${EXTENSION_URL}" > ext.tar.gz
  tar xvf ext.tar.gz

  # Ensure proper permissions
  chmod 755 steampipe_sqlite_github.so

  # Verify file type
  echo "Extension file type:"
  file steampipe_sqlite_github.so
fi

# Build the server with required flags and tags
echo "Building xmlui-test-server with extension loading support..."
SQLITE_INSTALL_DIR=$(pwd)/xmlui-test-server-build/sqlite-install
rm -f xmlui-test-server

# Set up the environment for go-sqlite3 with extension loading
CGO_ENABLED=1 \
CGO_CFLAGS="-I$SQLITE_INSTALL_DIR/include -DSQLITE_ENABLE_LOAD_EXTENSION -DSQLITE_ALLOW_LOAD_EXTENSION" \
CGO_LDFLAGS="$SQLITE_INSTALL_DIR/lib/libsqlite3.a -lm -ldl" \
go build -tags "sqlite3_load_extension" -v

# Verify the binary was built and check its dependencies
echo "Build complete. Checking binary dependencies:"
ls -la xmlui-test-server

# Make sure extension is executable
chmod 755 steampipe_sqlite_github.so

echo "Build process complete!"
echo ""
echo "To run the server:"
echo "./xmlui-test-server --extension ./steampipe_sqlite_github.so"
