#!/bin/bash
# Script to patch go-sqlite3 for SQLite extension loading
set -e

echo "🔧 Patching go-sqlite3 for SQLite extension loading..."

# Clone the repository if not already done
if [ ! -d "go-sqlite3" ]; then
  git clone https://github.com/mattn/go-sqlite3.git
fi

# Clean modcache to ensure a fresh build
go clean -modcache
go mod edit -replace github.com/mattn/go-sqlite3=./go-sqlite3
cd go-sqlite3

# 1. Apply robust extension loading patch
# First: Add the extension loading flags to CGO
echo "🔧 Adding SQLite extension loading flags to CGO..."
sed -i 's|#cgo CFLAGS:|#cgo CFLAGS: -DSQLITE_ENABLE_LOAD_EXTENSION=1 -DSQLITE_ALLOW_LOAD_EXTENSION=1|' sqlite3.go

# 2. Declare the C function in the Go code
# Add the C function declaration to the top of the file
echo "🔧 Declaring SQLite extension loading C functions..."
if ! grep -q "sqlite3_enable_load_extension" sqlite3.go; then
  sed -i '/^\/\/ #include <sqlite3ext.h>/a int sqlite3_enable_load_extension(sqlite3 *db, int onoff);' sqlite3.go
fi

# 3. Create a complete patch for enabling extension loading at connection time
echo "🔧 Creating LoadExtension method for SQLiteConn..."
cat > conn_patch.go << 'CONNEOF'
// LoadExtension loads a SQLite extension into the connection
func (c *SQLiteConn) LoadExtension(path string, entryPoint string) error {
	cPath := C.CString(path)
	defer C.free(unsafe.Pointer(cPath))

	var cEP *C.char
	if entryPoint != "" {
		cEP = C.CString(entryPoint)
		defer C.free(unsafe.Pointer(cEP))
	}

	db := c.db
	if db == nil {
		return errors.New("sqlite3 connection is closed")
	}

	// First, enable extension loading
	rv := C.sqlite3_enable_load_extension(db, 1)
	if rv != C.SQLITE_OK {
		return c.lastError()
	}

	var errMsg *C.char
	rv = C.sqlite3_load_extension(db, cPath, cEP, &errMsg)
	if rv != C.SQLITE_OK {
		defer C.sqlite3_free(unsafe.Pointer(errMsg))
		return errors.New(C.GoString(errMsg))
	}
	return nil
}
CONNEOF

# Check if the method already exists
if ! grep -q "func (c \*SQLiteConn) LoadExtension" conn.go; then
  # Add the LoadExtension method to conn.go
  sed -i '/^func (c \*SQLiteConn) Close() error {/i \
'"$(cat conn_patch.go)"'
' conn.go
fi

# 4. Create patch to enable extension loading at connection initialization
echo "🔧 Adding extension loading at connection initialization..."
cat > extension_patch.go << 'EXTEOF'
        // Enable extension loading immediately
        if rv := C.sqlite3_enable_load_extension(db, 1); rv != C.SQLITE_OK {
            fmt.Printf("Warning: Failed to enable extension loading: %d\n", rv)
        } else {
            fmt.Println("✅ Successfully enabled extension loading at connection time")
        }
EXTEOF

# Check if we've already inserted this patch
if ! grep -q "Successfully enabled extension loading at connection time" sqlite3.go; then
  # Insert the patch right after the db is opened
  sed -i '/return nil, errors.New("sqlite succeeded without returning a database")/r extension_patch.go' sqlite3.go
fi

# Clean up
rm -f extension_patch.go conn_patch.go

echo "✅ Patching complete!"