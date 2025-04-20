# sqlite-server

A lightweight HTTP server that:

- Serves static files from the current directory
- Provides a `/query` endpoint that sends SQL statements to a local SQLite database (data.db)
- Provides a `/proxy` endpoint so JavaScript clients can use APIs that don't support CORS
- Supports loading SQLite extensions (on both macOS and Linux)

## SQLite Extension Loading

This server includes support for loading SQLite extensions. Here's how the extension loading is implemented:

### Custom SQLite Build

The server requires a custom SQLite build with extension loading properly enabled:

```bash
# Custom SQLite build script (~/sqlite/build.sh)
CFLAGS="-DSQLITE_ENABLE_LOAD_EXTENSION -DSQLITE_ALLOW_LOAD_EXTENSION" ./configure --prefix=$HOME/sqlite/sqlite-autoconf-3450200
make CFLAGS="-DSQLITE_ENABLE_LOAD_EXTENSION -DSQLITE_ALLOW_LOAD_EXTENSION" -j4
make install
```

Both flags are crucial:
- `SQLITE_ENABLE_LOAD_EXTENSION`: Makes extension loading code available
- `SQLITE_ALLOW_LOAD_EXTENSION`: Enables security check to pass (prevents "not authorized" errors)

### Server Implementation

In the Go code, extensions are loaded with:

```go
// Open database with extension loading enabled
db, err := sql.Open("sqlite3", dbPath+"?_allow_load_extension=1")

// Get absolute path to extension
absPath, err := filepath.Abs("steampipe_sqlite_github.so")

// Load the extension using prepared statement
if _, err := db.Exec(`SELECT load_extension(?)`, absPath); err != nil {
    log.Printf("Note: extension loading failed: %v", err)
} else {
    log.Println("Extension loaded successfully")
}
```

### Building the Server

You can use the provided build scripts:

#### Automated Build (Recommended)

For Linux AMD64 systems, use:

```bash
./build-linux-amd.sh
```

This will:
- Download and build SQLite with extension loading enabled
- Download the appropriate Steampipe GitHub extension for your platform
- Build the SQLite server with the correct flags

#### MacOS ARM (Apple Silicon)

For macOS ARM (Apple Silicon), use the specialized build script:

```bash
./build-macos-arm.sh
```

This approach uses a locally patched version of go-sqlite3 to enable extension loading on M1/M2/M3 Macs.

#### Manual Build on macOS

The server must be built with specific flags to link against the custom SQLite:

```bash
CGO_ENABLED=1 \
CGO_CFLAGS="-I$HOME/sqlite/sqlite-autoconf-3450200/include" \
CGO_LDFLAGS="$HOME/sqlite/sqlite-autoconf-3450200/lib/libsqlite3.a -lm -ldl" \
go build -v
```

#### Manual Build on Linux

For Linux, you need to build SQLite with the same flags, and then build the server:

```bash
# Build SQLite with extension loading flags
wget https://www.sqlite.org/2024/sqlite-autoconf-3450200.tar.gz
tar xzf sqlite-autoconf-3450200.tar.gz
cd sqlite-autoconf-3450200

CFLAGS="-DSQLITE_ENABLE_LOAD_EXTENSION=1 -DSQLITE_ALLOW_LOAD_EXTENSION=1" ./configure
make CFLAGS="-DSQLITE_ENABLE_LOAD_EXTENSION=1 -DSQLITE_ALLOW_LOAD_EXTENSION=1" -j4

# Now build the server with appropriate flags
cd ..
CGO_ENABLED=1 \
CGO_CFLAGS="-I./sqlite-autoconf-3450200/include -DSQLITE_ENABLE_LOAD_EXTENSION=1 -DSQLITE_ALLOW_LOAD_EXTENSION=1" \
CGO_LDFLAGS="./sqlite-autoconf-3450200/.libs/libsqlite3.a -lm -ldl" \
go build -v
```

## API Endpoints

### Query Endpoint

```
POST /query
Content-Type: application/json

{
  "sql": "SELECT * FROM mytable",
  "params": []
}
```

### Proxy Endpoint

```
GET /proxy/api.example.com/v1/data
```

This will proxy the request to `https://api.example.com/v1/data`

## Running the Server

```bash
./sqlite-server
```

The server listens on port 8080 by default. You can specify a different port:

```bash
./sqlite-server -port 3000
```