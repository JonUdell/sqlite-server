# Unified SQLite Server Build

This document explains the unified build approach that works for both Linux and MacOS (including Apple Silicon).

## The Key to Extension Loading: Patched go-sqlite3

The critical discovery in making SQLite extension loading work across platforms is that the `go-sqlite3` module needs a single line patch:

```go
// Add this line after database creation in sqlite3.go (around line 1480)
C.sqlite3_enable_load_extension(db, 1);
```

This one-liner explicitly enables extension loading right after the database handle is created, resolving issues on all platforms.

## Unified Build Approach

Our unified build script (`build-unified.sh`) handles both platforms with a common approach:

1. For all platforms:
   - Use a patched version of go-sqlite3 with the critical one-liner
   - Use a `replace` directive in go.mod to point to the patched version
   - Build with `-tags "sqlite3_load_extension"` flag

2. Platform-specific differences:
   - MacOS ARM (Apple Silicon): Uses the patched go-sqlite3 with simple build flags
   - Linux/Other: Builds a custom SQLite with extension loading enabled and links against it

## Setting Up the Patched go-sqlite3

1. Clone the repository locally:
   ```bash
   git clone https://github.com/mattn/go-sqlite3.git ~/go-sqlite3
   ```

2. Edit `~/go-sqlite3/sqlite3.go` to add the one-liner:
   ```go
   // Around line 1480, after database creation
   C.sqlite3_enable_load_extension(db, 1);
   ```

3. Update your project's go.mod:
   ```
   replace github.com/mattn/go-sqlite3 => /path/to/your/go-sqlite3
   ```

## Building and Running

To build the server with the unified approach:

```bash
./build-unified.sh
```

This will create a platform-specific binary and a `sqlite-server` symlink.

To run the server:

```bash
./sqlite-server -port 8080
```

## Why This Works

The combination of:
1. The patched go-sqlite3 with the critical one-liner that enables extension loading
2. Building with the `sqlite3_load_extension` tag
3. For non-ARM platforms, building against a custom SQLite with extension loading flags

This approach ensures that the SQLite extension loading capability works correctly across all supported platforms.