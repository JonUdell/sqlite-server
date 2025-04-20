#!/bin/bash
set -e

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

# Download Steampipe SQLite extension for GitHub
echo "Downloading Steampipe SQLite extension for GitHub..."
if [ ! -f steampipe_sqlite_github.so ]; then
  curl -L https://github.com/turbot/steampipe-plugin-github/releases/download/v1.2.0/steampipe_sqlite_github.linux_amd64.tar.gz > ext.tar.gz
  tar xvf ext.tar.gz
fi

# Build the server with required flags and tags
echo "Building sqlite-server with extension loading support..."
SQLITE_INSTALL_DIR=$(pwd)/sqlite-server-build/sqlite-install
rm -f sqlite-server 

# Set up the environment for go-sqlite3 with extension loading
CGO_ENABLED=1 \
CGO_CFLAGS="-I$SQLITE_INSTALL_DIR/include -DSQLITE_ENABLE_LOAD_EXTENSION -DSQLITE_ALLOW_LOAD_EXTENSION" \
CGO_LDFLAGS="$SQLITE_INSTALL_DIR/lib/libsqlite3.a -lm -ldl" \
go build -tags "sqlite3_load_extension" -v

# Verify the binary was built and check its dependencies
echo "Build complete. Checking binary dependencies:"
ls -la sqlite-server
ldd sqlite-server

# Test if extensions are working
echo "Testing extension loading capabilities..."
./sqlite-server -port 8080 &
SERVER_PID=$!
sleep 3  # Give server time to start

curl -X POST -H "Content-Type: application/json" -d '{"sql":"SELECT sqlite_version()"}' http://localhost:8080/query

# Kill the server
kill $SERVER_PID

echo "Build process complete!"