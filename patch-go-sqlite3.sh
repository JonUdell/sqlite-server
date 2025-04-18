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
if grep -q "#cgo CFLAGS:" sqlite3.go; then
  # For macOS, use different sed syntax
  if [ "$(uname)" = "Darwin" ]; then
    sed -i '' 's|#cgo CFLAGS:|#cgo CFLAGS: -DSQLITE_ENABLE_LOAD_EXTENSION=1 -DSQLITE_ALLOW_LOAD_EXTENSION=1|' sqlite3.go
  else
    sed -i 's|#cgo CFLAGS:|#cgo CFLAGS: -DSQLITE_ENABLE_LOAD_EXTENSION=1 -DSQLITE_ALLOW_LOAD_EXTENSION=1|' sqlite3.go
  fi
else
  echo "⚠️ Could not find '#cgo CFLAGS:' in sqlite3.go"
fi

# 2. Declare the C function in the Go code
# Add the C function declaration to the top of the file if not already there
echo "🔧 Declaring SQLite extension loading C functions..."
if ! grep -q "sqlite3_enable_load_extension" sqlite3.go; then
  # For macOS, use different sed syntax
  if [ "$(uname)" = "Darwin" ]; then
    sed -i '' '/^\/\/ #include <sqlite3ext.h>/a\'$'\n''int sqlite3_enable_load_extension(sqlite3 *db, int onoff);' sqlite3.go
  else
    sed -i '/^\/\/ #include <sqlite3ext.h>/a int sqlite3_enable_load_extension(sqlite3 *db, int onoff);' sqlite3.go
  fi
fi

# 3. Enable extension loading at connection initialization
echo "🔧 Adding extension loading at connection initialization..."
# Create patch for enabling extension loading when opening a connection
if ! grep -q "Successfully enabled extension loading at connection time" sqlite3.go; then
  cat > extension_patch.go << 'EXTEOF'
        // Enable extension loading immediately
        if rv := C.sqlite3_enable_load_extension(db, 1); rv != C.SQLITE_OK {
            fmt.Printf("Warning: Failed to enable extension loading: %d\n", rv)
        } else {
            fmt.Println("✅ Successfully enabled extension loading at connection time")
        }
EXTEOF

  # Insert the patch right after the database is opened
  # Find a good spot to insert the code, just after the database is created successfully
  if [ "$(uname)" = "Darwin" ]; then
    # For macOS, save the line number then use it with ed
    LINE_NUM=$(grep -n "return nil, errors.New(\"sqlite succeeded without returning a database\")" sqlite3.go | cut -d':' -f1)
    if [ -n "$LINE_NUM" ]; then
      ed -s sqlite3.go << EOF
${LINE_NUM}a
$(cat extension_patch.go)
.
w
q
EOF
    fi
  else
    sed -i '/return nil, errors.New("sqlite succeeded without returning a database")/r extension_patch.go' sqlite3.go
  fi
  rm -f extension_patch.go
fi

# 4. Make sure LoadExtension method is properly enabled
echo "🔧 Ensuring LoadExtension method is enabled..."

# Instead of just commenting out the omit file, create a proper Go file
if [ -f "sqlite3_load_extension_omit.go" ]; then
  cat > sqlite3_load_extension_omit.go << 'OMITFILE'
// Copyright (C) 2019 Yasuhiro Matsumoto <mattn.jp@gmail.com>.
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file.

//go:build sqlite_omit_load_extension
// +build sqlite_omit_load_extension

package sqlite3

// This file is intentionally empty to prevent build issues
// LoadExtension is enabled in this build through sqlite3_load_extension.go
OMITFILE
fi

if [ -f "sqlite3_load_extension.go" ]; then
  echo "✅ LoadExtension method already exists in sqlite3_load_extension.go"
else
  # If for some reason the file is missing, create it
  echo "🔧 Creating LoadExtension method file..."
  cat > sqlite3_load_extension.go << 'EXTFILE'
// Copyright (C) 2019 Yasuhiro Matsumoto <mattn.jp@gmail.com>.
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file.

//go:build !sqlite_omit_load_extension
// +build !sqlite_omit_load_extension

package sqlite3

/*
#ifndef USE_LIBSQLITE3
#include "sqlite3-binding.h"
#else
#include <sqlite3.h>
#endif
#include <stdlib.h>
*/
import "C"
import (
	"errors"
	"unsafe"
)

func (c *SQLiteConn) loadExtensions(extensions []string) error {
	rv := C.sqlite3_enable_load_extension(c.db, 1)
	if rv != C.SQLITE_OK {
		return errors.New(C.GoString(C.sqlite3_errmsg(c.db)))
	}

	for _, extension := range extensions {
		if err := c.loadExtension(extension, nil); err != nil {
			C.sqlite3_enable_load_extension(c.db, 0)
			return err
		}
	}

	rv = C.sqlite3_enable_load_extension(c.db, 0)
	if rv != C.SQLITE_OK {
		return errors.New(C.GoString(C.sqlite3_errmsg(c.db)))
	}

	return nil
}

// LoadExtension load the sqlite3 extension.
func (c *SQLiteConn) LoadExtension(lib string, entry string) error {
	rv := C.sqlite3_enable_load_extension(c.db, 1)
	if rv != C.SQLITE_OK {
		return errors.New(C.GoString(C.sqlite3_errmsg(c.db)))
	}

	if err := c.loadExtension(lib, &entry); err != nil {
		C.sqlite3_enable_load_extension(c.db, 0)
		return err
	}

	rv = C.sqlite3_enable_load_extension(c.db, 0)
	if rv != C.SQLITE_OK {
		return errors.New(C.GoString(C.sqlite3_errmsg(c.db)))
	}

	return nil
}

func (c *SQLiteConn) loadExtension(lib string, entry *string) error {
	clib := C.CString(lib)
	defer C.free(unsafe.Pointer(clib))

	var centry *C.char
	if entry != nil {
		centry = C.CString(*entry)
		defer C.free(unsafe.Pointer(centry))
	}

	var errMsg *C.char
	defer C.sqlite3_free(unsafe.Pointer(errMsg))

	rv := C.sqlite3_load_extension(c.db, clib, centry, &errMsg)
	if rv != C.SQLITE_OK {
		return errors.New(C.GoString(errMsg))
	}

	return nil
}
EXTFILE
fi

echo "✅ Patching complete!"