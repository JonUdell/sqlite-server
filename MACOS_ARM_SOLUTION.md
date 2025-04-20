# SQLite Extension Loading on MacOS ARM (Apple Silicon)

## The Problem

On MacOS ARM (M1/M2/M3 Macs), loading SQLite extensions can be challenging because:

1. The default go-sqlite3 library doesn't properly support extension loading on ARM64 architecture
2. Standard builds using custom SQLite with extension loading flags would still fail

## The Solution

We implemented a solution that involves:

1. Using a patched version of the go-sqlite3 library
2. Building with specific compiler flags
3. Using a replace directive in go.mod to point to the local patched library

### Steps to Reproduce the Solution

1. **Clone the go-sqlite3 library locally**

   ```bash
   git clone https://github.com/mattn/go-sqlite3.git ~/go-sqlite3
   ```

2. **Add a replace directive in go.mod**

   ```
   replace github.com/mattn/go-sqlite3 => /Users/jonudell/go-sqlite3
   ```

3. **Build with extension loading flags**

   ```bash
   CGO_ENABLED=1 \
   CGO_CFLAGS="-DSQLITE_ENABLE_LOAD_EXTENSION -DSQLITE_ALLOW_LOAD_EXTENSION" \
   go build -tags "sqlite3_load_extension" -v -o sqlite-server-macos-arm sqlite-server.go
   ```

4. **Run the server**

   ```bash
   ./sqlite-server-macos-arm
   ```

## Verification

When running successfully, you should see log output like:

```
2025/04/19 23:19:16 sqlite-server.go:213: Server starting...
2025/04/19 23:19:16 sqlite-server.go:220: Working directory: /Users/jonudell/sqlite-server
...
2025/04/19 23:19:16 sqlite-server.go:65: Trying to load extension: /Users/jonudell/sqlite-server/steampipe_sqlite_github.so
2025/04/19 23:19:17 sqlite-server.go:71: Extension loaded successfully
```

## Why This Works

The patched library properly configures the SQLite build for ARM64 architecture. The key flags:

- `CGO_ENABLED=1`: Enables CGO to interface with C libraries
- `CGO_CFLAGS="-DSQLITE_ENABLE_LOAD_EXTENSION -DSQLITE_ALLOW_LOAD_EXTENSION"`: Ensures SQLite is built with extension loading enabled
- `-tags "sqlite3_load_extension"`: Enables the extension loading code in go-sqlite3

## For Future Work

For a more permanent solution:
1. Fork the go-sqlite3 library
2. Apply the necessary patches
3. Create a pull request to upstream for better ARM64 support
4. Update the build process to handle architecture-specific builds automatically