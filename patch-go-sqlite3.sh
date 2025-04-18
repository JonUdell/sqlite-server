#!/bin/bash
# Enhanced script to patch go-sqlite3 for SQLite extension loading
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

echo "🔍 Current directory structure:"
ls -la

# 1. Add extension flags to ALL cgo directives in ALL files
echo "🔧 Adding SQLite extension loading flags to ALL CGO directives..."
for file in *.go; do
  if grep -q "#cgo" "$file"; then
    echo "  - Adding flags to $file"
    if [ "$(uname)" = "Darwin" ]; then
      sed -i '' 's|#cgo CFLAGS:|#cgo CFLAGS: -DSQLITE_ENABLE_LOAD_EXTENSION=1 -DSQLITE_ALLOW_LOAD_EXTENSION=1|g' "$file"
    else
      sed -i 's|#cgo CFLAGS:|#cgo CFLAGS: -DSQLITE_ENABLE_LOAD_EXTENSION=1 -DSQLITE_ALLOW_LOAD_EXTENSION=1|g' "$file"
    fi
  fi
done

# 2. Create a special file with JUST the extension loading flags
echo "🔧 Creating dedicated extension flags file..."
cat > _load_extension_flags.go << 'EOF'
// Copyright (C) 2014 Yasuhiro Matsumoto <mattn.jp@gmail.com>.
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file.

package sqlite3

/*
#cgo CFLAGS: -DSQLITE_ENABLE_LOAD_EXTENSION=1 -DSQLITE_ALLOW_LOAD_EXTENSION=1
*/
import "C"

// This file ensures extension loading CFLAGS are always included
EOF

# 3. Create a special file with the C function declaration
echo "🔧 Creating dedicated extension function declarations file..."
cat > _load_extension_funcs.go << 'EOF'
// Copyright (C) 2014 Yasuhiro Matsumoto <mattn.jp@gmail.com>.
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file.

package sqlite3

/*
#ifndef USE_LIBSQLITE3
#include "sqlite3-binding.h"
#else
#include <sqlite3.h>
#endif
#include <stdlib.h>

// Explicitly declare extension loading functions
int sqlite3_enable_load_extension(sqlite3 *db, int onoff);
int sqlite3_load_extension(sqlite3 *db, const char *zFile, const char *zProc, char **pzErrMsg);
*/
import "C"

// This file ensures extension loading functions are properly declared
EOF

# 4. Properly implement the LoadExtension method
echo "🔧 Ensuring LoadExtension is properly implemented..."

# 4.1 Fix the omit file to be properly empty with package declaration
cat > sqlite3_load_extension_omit.go << 'EOF'
// Copyright (C) 2014 Yasuhiro Matsumoto <mattn.jp@gmail.com>.
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file.

//go:build sqlite_omit_load_extension
// +build sqlite_omit_load_extension

package sqlite3

// This file is intentionally empty - extension loading is enabled
EOF

# 4.2 Ensure we have a proper implementation of the LoadExtension method
if [ -f "sqlite3_load_extension.go" ]; then
  echo "  - LoadExtension method already exists, backing up and replacing with enhanced version"
  cp sqlite3_load_extension.go sqlite3_load_extension.go.bak
fi

cat > sqlite3_load_extension.go << 'EOF'
// Copyright (C) 2014 Yasuhiro Matsumoto <mattn.jp@gmail.com>.
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

// Explicitly declare extension loading functions
int sqlite3_enable_load_extension(sqlite3 *db, int onoff);
int sqlite3_load_extension(sqlite3 *db, const char *zFile, const char *zProc, char **pzErrMsg);
*/
import "C"
import (
	"errors"
	"fmt"
	"unsafe"
)

// LoadExtension loads a SQLite extension into the connection
func (c *SQLiteConn) LoadExtension(path string, entryPoint string) error {
	fmt.Printf("🔍 LoadExtension called for %s (entry point: %s)\n", path, entryPoint)

	if c == nil {
		return errors.New("nil sqlite connection")
	}

	if c.db == nil {
		return errors.New("sqlite3 connection is closed")
	}

	cPath := C.CString(path)
	defer C.free(unsafe.Pointer(cPath))

	var cEntry *C.char
	if entryPoint != "" {
		cEntry = C.CString(entryPoint)
		defer C.free(unsafe.Pointer(cEntry))
	}

	// First, explicitly enable extension loading
	fmt.Println("🔧 Enabling extension loading...")
	rv := C.sqlite3_enable_load_extension(c.db, 1)
	if rv != C.SQLITE_OK {
		errStr := C.GoString(C.sqlite3_errmsg(c.db))
		fmt.Printf("❌ Failed to enable extension loading: %s (%d)\n", errStr, rv)
		return fmt.Errorf("failed to enable extension loading: %s (%d)", errStr, rv)
	}
	fmt.Println("✅ Extension loading enabled")

	// Try to load the extension
	fmt.Printf("🔧 Loading extension %s...\n", path)
	var errMsg *C.char
	rv = C.sqlite3_load_extension(c.db, cPath, cEntry, &errMsg)
	
	if rv != C.SQLITE_OK {
		var errStr string
		if errMsg != nil {
			errStr = C.GoString(errMsg)
			C.sqlite3_free(unsafe.Pointer(errMsg))
		} else {
			errStr = C.GoString(C.sqlite3_errmsg(c.db))
		}
		fmt.Printf("❌ Failed to load extension: %s (%d)\n", errStr, rv)
		
		// Disable extension loading before returning
		C.sqlite3_enable_load_extension(c.db, 0)
		return fmt.Errorf("failed to load extension: %s (%d)", errStr, rv)
	}

	fmt.Printf("✅ Extension %s loaded successfully\n", path)
	
	// For safety, disable extension loading after successful load
	rv = C.sqlite3_enable_load_extension(c.db, 0)
	if rv != C.SQLITE_OK {
		fmt.Printf("⚠️ Warning: Failed to disable extension loading: %s\n", C.GoString(C.sqlite3_errmsg(c.db)))
	}

	return nil
}

// EnableLoadExtension enables or disables SQLite extension loading
func (c *SQLiteConn) EnableLoadExtension(enable bool) error {
	if c == nil {
		return errors.New("nil sqlite connection")
	}

	if c.db == nil {
		return errors.New("sqlite3 connection is closed")
	}

	onoff := 0
	if enable {
		onoff = 1
	}

	rv := C.sqlite3_enable_load_extension(c.db, C.int(onoff))
	if rv != C.SQLITE_OK {
		return errors.New(C.GoString(C.sqlite3_errmsg(c.db)))
	}

	return nil
}

// loadExtensions loads multiple extensions at once
func (c *SQLiteConn) loadExtensions(extensions []string) error {
	if len(extensions) == 0 {
		return nil
	}
	
	fmt.Printf("🔍 loadExtensions called with %d extensions\n", len(extensions))
	
	// Enable extension loading
	rv := C.sqlite3_enable_load_extension(c.db, 1)
	if rv != C.SQLITE_OK {
		return errors.New(C.GoString(C.sqlite3_errmsg(c.db)))
	}

	// Load each extension
	for _, extension := range extensions {
		cPath := C.CString(extension)
		var errMsg *C.char
		fmt.Printf("🔍 Loading extension: %s\n", extension)
		rv := C.sqlite3_load_extension(c.db, cPath, nil, &errMsg)
		C.free(unsafe.Pointer(cPath))
		
		if rv != C.SQLITE_OK {
			// Disable extension loading before returning
			C.sqlite3_enable_load_extension(c.db, 0)
			
			if errMsg != nil {
				errStr := C.GoString(errMsg)
				C.sqlite3_free(unsafe.Pointer(errMsg))
				return errors.New(errStr)
			}
			return errors.New(C.GoString(C.sqlite3_errmsg(c.db)))
		}
	}

	// Disable extension loading
	rv = C.sqlite3_enable_load_extension(c.db, 0)
	if rv != C.SQLITE_OK {
		return errors.New(C.GoString(C.sqlite3_errmsg(c.db)))
	}

	fmt.Println("✅ All extensions loaded successfully")
	return nil
}
EOF

# 5. Add code to auto-enable extension loading
echo "🔧 Adding auto-enabling of extension loading at connection time..."

# Create a new file with a function that auto-enables extension loading
cat > auto_enable_extensions.go << 'EOF'
// Copyright (C) 2014 Yasuhiro Matsumoto <mattn.jp@gmail.com>.
//
// Use of this source code is governed by an MIT-style
// license that can be found in the LICENSE file.

package sqlite3

/*
#ifndef USE_LIBSQLITE3
#include "sqlite3-binding.h"
#else
#include <sqlite3.h>
#endif
#include <stdlib.h>

// Explicitly declare extension loading functions
int sqlite3_enable_load_extension(sqlite3 *db, int onoff);
*/
import "C"
import "fmt"

// autoEnableLoadExtension is called during connection initialization
func autoEnableLoadExtension(db *C.sqlite3) {
	fmt.Println("🔧 Auto-enabling extension loading...")
	rv := C.sqlite3_enable_load_extension(db, 1)
	if rv != C.SQLITE_OK {
		fmt.Printf("⚠️ WARNING: Failed to auto-enable extension loading: %d\n", rv)
	} else {
		fmt.Println("✅ Extension loading auto-enabled at connection time")
	}
}
EOF

# 6. Patch sqlite3.go to call our auto-enable function
echo "🔧 Patching sqlite3.go to call auto-enable function..."

# Find suitable locations after the database is opened to add our auto-enable call
if [ "$(uname)" = "Darwin" ]; then
  # First location - the main handle init after openDB
  LINE_NUM=$(grep -n "func (d \\*SQLiteDriver) Open" sqlite3.go | head -1 | cut -d':' -f1)
  if [ -n "$LINE_NUM" ]; then
    FUNC_START=$LINE_NUM
    OPEN_LINE=$(grep -n -A 50 "func (d \\*SQLiteDriver) Open" sqlite3.go | grep -n "var db \\*C.sqlite3" | head -1 | cut -d':' -f1)
    if [ -n "$OPEN_LINE" ]; then
      OPEN_LINE=$((FUNC_START + OPEN_LINE - 1))
      HANDLE_LINE=$((OPEN_LINE + 10)) # Approximate line where the handle is created
      
      # Add an auto-enable call right after the handle is created
      LINE_NUM=$(grep -n -A 50 "func (d \\*SQLiteDriver) Open" sqlite3.go | grep -n "db, rv := C.sqlite3_open_v2" | head -1 | cut -d':' -f1)
      if [ -n "$LINE_NUM" ]; then
        LINE_NUM=$((FUNC_START + LINE_NUM - 1 + 2)) # +2 to get past the if check
        ed -s sqlite3.go << EOF
${LINE_NUM}a
	// Auto-enable extension loading
	autoEnableLoadExtension(db)
.
w
q
EOF
      fi
    fi
  fi
else
  # For Linux, use sed to insert our call
  PATTERN="db, rv := C.sqlite3_open_v2"
  LINE_NUM=$(grep -n "$PATTERN" sqlite3.go | head -1 | cut -d':' -f1)
  if [ -n "$LINE_NUM" ]; then
    # Find the next line that's not empty and add our code after it
    NEXT_LINE=$((LINE_NUM + 2))
    sed -i "${NEXT_LINE}a \\	// Auto-enable extension loading\\n\\tautoEnableLoadExtension(db)" sqlite3.go
  fi
fi

echo "✅ Patching complete!"

# Go back to the main directory
cd ..

echo "🔍 go.mod file details:"
cat go.mod