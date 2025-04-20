#!/bin/bash
set -e

echo "SQLite Server Unified Build Script"
echo "=================================="

# Detect platform
OS_TYPE=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)
if [[ "$ARCH" == "x86_64" ]]; then
  ARCH="amd64"
elif [[ "$ARCH" == "arm64" || "$ARCH" == "aarch64" ]]; then
  ARCH="arm64"
fi

echo "Detected platform: ${OS_TYPE}_${ARCH}"

# Set output binary name based on platform
OUTPUT_BINARY="sqlite-server-${OS_TYPE}-${ARCH}"

# IMPORTANT NOTICE: The Patched go-sqlite3 Requirement
echo ""
echo "=== IMPORTANT: Using Patched go-sqlite3 ==="
echo "This build requires a patched version of go-sqlite3 that enables"
echo "extension loading by adding 'C.sqlite3_enable_load_extension(db, 1);'"
echo "at line ~1480 in sqlite3.go. This critical one-liner is needed for"
echo "ALL platforms to enable extension loading."
echo ""
echo "Your go.mod file must have this replace directive:"
echo "replace github.com/mattn/go-sqlite3 => /path/to/patched/go-sqlite3"
echo "================================================================"
echo ""

# Check if the patched go-sqlite3 exists based on go.mod
if ! grep -q "replace github.com/mattn/go-sqlite3" go.mod; then
  echo "Error: go.mod does not contain the replace directive for go-sqlite3"
  echo "Please add 'replace github.com/mattn/go-sqlite3 => /path/to/patched/go-sqlite3' to go.mod"
  exit 1
fi

# Extract the patched go-sqlite3 path from go.mod
GO_SQLITE3_PATH=$(grep "replace github.com/mattn/go-sqlite3" go.mod | sed -E 's/.*=> (.*)/\1/')
echo "Using patched go-sqlite3 from: $GO_SQLITE3_PATH"

# Verify the patched file exists and contains the critical one-liner
if [ ! -f "${GO_SQLITE3_PATH}/sqlite3.go" ]; then
  echo "Error: Could not find sqlite3.go in $GO_SQLITE3_PATH"
  exit 1
fi

if ! grep -q "sqlite3_enable_load_extension.*1" "${GO_SQLITE3_PATH}/sqlite3.go"; then
  echo "Warning: Could not find 'sqlite3_enable_load_extension' in ${GO_SQLITE3_PATH}/sqlite3.go"
  echo "The patched version might be missing the critical one-liner!"
  echo "Make sure 'C.sqlite3_enable_load_extension(db, 1);' is added after database creation"
fi

# Download Steampipe SQLite extension for GitHub if not already present
if [ ! -f steampipe_sqlite_github.so ]; then
  echo "Downloading Steampipe SQLite extension for GitHub..."
  EXTENSION_URL="https://github.com/turbot/steampipe-plugin-github/releases/download/v1.2.0/steampipe_sqlite_github.${OS_TYPE}_${ARCH}.tar.gz"
  echo "Downloading extension from ${EXTENSION_URL}"
  
  curl -L "${EXTENSION_URL}" > ext.tar.gz
  tar xvf ext.tar.gz
  
  # Ensure proper permissions
  chmod 755 steampipe_sqlite_github.so
  
  # Verify file type
  echo "Extension file type:"
  file steampipe_sqlite_github.so
fi

# Build process differences by platform
if [[ "$OS_TYPE" == "darwin" && "$ARCH" == "arm64" ]]; then
  # MacOS ARM doesn't need custom SQLite - use patched go-sqlite3 directly
  echo "Building for MacOS ARM (Apple Silicon)..."
  
  # Build with patched go-sqlite3
  rm -f "$OUTPUT_BINARY"
  
  # Set up the environment for go-sqlite3 with extension loading
  CGO_ENABLED=1 \
  CGO_CFLAGS="-DSQLITE_ENABLE_LOAD_EXTENSION -DSQLITE_ALLOW_LOAD_EXTENSION" \
  go build -tags "sqlite3_load_extension" -v -o "$OUTPUT_BINARY" sqlite-server.go
  
else
  # Other platforms (Linux, MacOS Intel) - use custom SQLite build
  echo "Building with custom SQLite for ${OS_TYPE}_${ARCH}..."
  
  # Create a clean working directory
  echo "Creating clean working directory..."
  mkdir -p sqlite-server-build
  cd sqlite-server-build
  
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
  
  # Build the server with required flags and tags
  echo "Building sqlite-server with extension loading support..."
  SQLITE_INSTALL_DIR=$(pwd)/sqlite-server-build/sqlite-install
  rm -f "$OUTPUT_BINARY"
  
  # Set up the environment for go-sqlite3 with extension loading
  # Still using patched go-sqlite3, but with custom SQLite build
  CGO_ENABLED=1 \
  CGO_CFLAGS="-I$SQLITE_INSTALL_DIR/include -DSQLITE_ENABLE_LOAD_EXTENSION -DSQLITE_ALLOW_LOAD_EXTENSION" \
  CGO_LDFLAGS="$SQLITE_INSTALL_DIR/lib/libsqlite3.a -lm -ldl" \
  go build -tags "sqlite3_load_extension" -v -o "$OUTPUT_BINARY" sqlite-server.go
fi

# Create symlink for convenience
ln -sf "$OUTPUT_BINARY" sqlite-server

# Verify the binary was built and check its dependencies
echo "Build complete. Checking binary:"
ls -la "$OUTPUT_BINARY"

# Check binary dependencies using platform-specific commands
if [[ "$OS_TYPE" == "darwin" ]]; then
  # macOS uses otool instead of ldd
  otool -L "$OUTPUT_BINARY"
else
  # Linux uses ldd
  ldd "$OUTPUT_BINARY"
fi

# Make sure extension is executable
chmod 755 steampipe_sqlite_github.so

echo ""
echo "Build process complete!"
echo "To run the server: ./sqlite-server -port 8080"
echo "Or use the platform-specific binary: ./$OUTPUT_BINARY -port 8080"