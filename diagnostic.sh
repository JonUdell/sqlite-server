#!/bin/bash
# SQLite Extension Loading Diagnostic Script
set -e

echo "🔍 SQLite Extension Loading Diagnostic"
echo "====================================="

# Install dependencies
echo -e "\n📦 Installing dependencies..."
sudo apt-get update
sudo apt-get install -y gcc make wget sqlite3 libsqlite3-dev

# Check system SQLite
echo -e "\n🔍 Checking system SQLite version and compile options:"
sqlite3 --version
echo "PRAGMA compile_options;" | sqlite3 :memory:

# Check if extension loading is enabled
echo -e "\n🔍 Checking if extension loading is enabled in system SQLite:"
echo "SELECT 1 FROM pragma_compile_options WHERE compile_options LIKE '%ENABLE_LOAD_EXTENSION%';" | sqlite3 :memory:
echo "SELECT 1 FROM pragma_compile_options WHERE compile_options LIKE '%ALLOW_LOAD_EXTENSION%';" | sqlite3 :memory:

# Build custom SQLite
echo -e "\n📦 Building custom SQLite with extension loading..."
wget https://www.sqlite.org/2024/sqlite-autoconf-3450300.tar.gz
tar xzf sqlite-autoconf-3450300.tar.gz
cd sqlite-autoconf-3450300

export CFLAGS="-DSQLITE_ENABLE_LOAD_EXTENSION=1 -DSQLITE_ALLOW_LOAD_EXTENSION=1"
./configure --prefix=$HOME/sqlite

# Force patch Makefile
sed -i 's|^CFLAGS = |CFLAGS = -DSQLITE_ENABLE_LOAD_EXTENSION=1 -DSQLITE_ALLOW_LOAD_EXTENSION=1 |' Makefile

echo "🔍 Checking Makefile for compile flags:"
grep -i allow_load_extension Makefile || true
grep -i enable_load_extension Makefile || true

make CFLAGS="$CFLAGS" -j4
make install

echo "🔍 Checking custom SQLite compile options:"
echo "PRAGMA compile_options;" | $HOME/sqlite/bin/sqlite3 :memory:

# Check for extension loading function
echo -e "\n🔍 Checking for sqlite3_enable_load_extension in libsqlite3.a:"
nm -g $HOME/sqlite/lib/libsqlite3.a | grep sqlite3_enable_load_extension || echo "Symbol not found"

cd ..

# Create test extension
echo -e "\n📦 Creating a simple test extension..."
cat > test_extension.c << 'EXTC'
#include <sqlite3ext.h>
#include <stddef.h>  /* For NULL */
SQLITE_EXTENSION_INIT1

/* Function needs to be 'void' not 'int' to match expected callback type */
static void hello_world(sqlite3_context *context, int argc, sqlite3_value **argv) {
  sqlite3_result_text(context, "Hello from extension!", -1, SQLITE_TRANSIENT);
}

int sqlite3_testextension_init(sqlite3 *db, char **pzErrMsg, const sqlite3_api_routines *pApi) {
  SQLITE_EXTENSION_INIT2(pApi);
  sqlite3_create_function(db, "hello_ext", 0, SQLITE_UTF8, NULL, hello_world, NULL, NULL);
  return SQLITE_OK;
}
EXTC

gcc -fPIC -shared -o test_extension.so test_extension.c -I$HOME/sqlite/include

# Patch go-sqlite3 using our script
echo -e "\n🔧 Patching go-sqlite3 using patch-go-sqlite3.sh..."
chmod +x ./patch-go-sqlite3.sh
./patch-go-sqlite3.sh

# Create Go test program
echo -e "\n📦 Creating Go test program..."
cat > test_program.go << 'GOFILE'
package main

import (
	"database/sql"
	"fmt"
	"log"
	"os"
	"path/filepath"
	_ "github.com/mattn/go-sqlite3"
)

func main() {
	log.SetFlags(log.LstdFlags | log.Lshortfile)
	
	fmt.Println("🔍 SQLite Extension Loading Test")
	fmt.Println("==============================")
	
	// Print current working directory and files
	pwd, _ := os.Getwd()
	fmt.Printf("Working directory: %s\n", pwd)
	
	files, _ := filepath.Glob("*.so")
	fmt.Printf("SO files in directory: %v\n", files)
	
	// Open database with extension loading enabled
	fmt.Println("\n🔍 Opening database with _allow_load_extension=1...")
	db, err := sql.Open("sqlite3", "test.db?_allow_load_extension=1")
	if err != nil {
		log.Fatalf("Failed to open database: %v", err)
	}
	defer db.Close()
	
	// Check SQLite version
	var version string
	if err := db.QueryRow("SELECT sqlite_version()").Scan(&version); err != nil {
		fmt.Printf("Failed to get SQLite version: %v\n", err)
	} else {
		fmt.Printf("SQLite version: %s\n", version)
	}
	
	// Print compile options
	rows, err := db.Query("PRAGMA compile_options;")
	if err != nil {
		fmt.Printf("Failed to query compile options: %v\n", err)
	} else {
		fmt.Println("SQLite compile options:")
		for rows.Next() {
			var option string
			rows.Scan(&option)
			fmt.Printf("  %s\n", option)
		}
		rows.Close()
	}
	
	// Try loading the extension
	extensionPath := "./test_extension.so"
	absPath, _ := filepath.Abs(extensionPath)
	fmt.Printf("\nLoading extension from: %s\n", absPath)
	
	// Verify extension file permissions and existence
	if fileInfo, err := os.Stat(extensionPath); err != nil {
		fmt.Printf("Extension file error: %v\n", err)
	} else {
		fmt.Printf("Extension file permissions: %v\n", fileInfo.Mode())
		fmt.Printf("Extension file size: %d bytes\n", fileInfo.Size())
	}
	
	// Try loading the extension
	fmt.Println("\n🔍 Attempting to load extension...")
	_, err = db.Exec("SELECT load_extension(?)", absPath)
	if err != nil {
		fmt.Printf("FAILED: %v\n", err)
	} else {
		fmt.Println("Successfully loaded extension!")
		
		// Test extension function
		var hello string
		err := db.QueryRow("SELECT hello_ext()").Scan(&hello)
		if err != nil {
			fmt.Printf("Failed to call extension function: %v\n", err)
		} else {
			fmt.Printf("Extension function result: %s\n", hello)
		}
	}
}
GOFILE

# Test with static linking (like the Linux build in GitHub Actions)
echo -e "\n🧪 Testing with static linking..."
export CGO_ENABLED=1
export CGO_CFLAGS="-I$HOME/sqlite/include -DSQLITE_ENABLE_LOAD_EXTENSION=1 -DSQLITE_ALLOW_LOAD_EXTENSION=1"
export CGO_LDFLAGS="-static $HOME/sqlite/lib/libsqlite3.a -ldl -lm"
go build -tags "sqlite3_load_extension" -ldflags="-linkmode external" -v -o test_static test_program.go
./test_static

echo -e "\n✅ Diagnostic complete!"