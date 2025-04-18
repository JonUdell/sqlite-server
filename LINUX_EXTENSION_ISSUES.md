# SQLite Extension Loading Issues on Linux

## Problem Summary

When using go-sqlite3 on Linux environments, loading SQLite extensions encounters "not authorized" errors despite the same code working correctly on macOS.

## Root Cause

The fundamental issue is:

- **On macOS**: The system links against Homebrew's libsqlite3.dylib which is already built with `ENABLE_LOAD_EXTENSION=1`
- **On Linux**: The go-sqlite3 driver compiles its own SQLite amalgamation with conservative defaults, generally **without** `ENABLE_LOAD_EXTENSION`

This difference explains why identical code works on macOS but fails on Linux.

## Key Observations

1. **Error Source**: The "not authorized" string comes directly from the first guard check in `sqlite3_load_extension()` function, which verifies both compile-time and run-time extension loading flags are enabled.

2. **Diagnostic Steps**:
   - Checking `PRAGMA compile_options` should specifically confirm if `ENABLE_LOAD_EXTENSION` is present or if `OMIT_LOAD_EXTENSION` appears
   - Empty results from `PRAGMA compile_options` indicates a stripped-down amalgamation

3. **Why PRAGMA appears to succeed**: The `PRAGMA enable_load_extension = 1` command may succeed but still fail to actually enable extensions if the compile-time flag is missing

## Attempted Solutions (So Far)

1. **Build Flags**:
   - Compiling SQLite with `-DSQLITE_ENABLE_LOAD_EXTENSION=1 -DSQLITE_ALLOW_LOAD_EXTENSION=1`
   - Building with tags: `sqlite_allow_load_extension sqlite_enable_load_extension`

2. **Connection Parameters**:
   - Using `?_allow_load_extension=1` in the connection string
   - Running `PRAGMA enable_load_extension = 1` before loading

3. **Low-Level Approaches**:
   - Using LD_PRELOAD to inject a custom C library
   - Custom auto-extension registration code

## Solution Checklist

1. **Verify SQLite Compilation Options**:
   ```go
   rows, _ := db.Query(`PRAGMA compile_options`)
   for rows.Next() { 
       var opt string
       rows.Scan(&opt)
       fmt.Println(opt) 
   }
   ```
   Confirm `ENABLE_LOAD_EXTENSION` is present and `OMIT_LOAD_EXTENSION` is absent.

2. **Rebuild go-sqlite3 with Extension Support**:  
   Choose one of these approaches:

   - **Link to system SQLite** (if your distro has it built with extension support):
     ```
     go build -tags "libsqlite3"
     ```

   - **Keep the amalgamation but add extension support flag**:
     ```
     CGO_CFLAGS="-DSQLITE_ENABLE_LOAD_EXTENSION" go build
     ```

3. **Tell the Go Driver to Allow Extensions**:
   Even with the flag set, go-sqlite3 blocks runtime loading unless you opt-in:

   - **Register a driver that whitelists specific extensions**:
     ```go
     sql.Register("sqlite+ext",
         &sqlite3.SQLiteDriver{
             Extensions: []string{"/absolute/path/to/myext.so"},
         })
     db, _ := sql.Open("sqlite+ext", "file:test.db?_allow_load_extension=1")
     ```

   - **Use a ConnectHook to enable for all extensions**:
     ```go
     sql.Register("sqlite+any",
         &sqlite3.SQLiteDriver{
             ConnectHook: func(conn *sqlite3.SQLiteConn) error {
                 return conn.EnableLoadExtension(true)  // enables but doesn't load
             },
         })
     ```

4. **Additional Troubleshooting**:
   - **Path/permissions**: Ensure the shared object is world-readable and built for the correct architecture
   - **Missing -ldl**: Static musl builds sometimes drop the dynamic-loader stub; rebuild with `CGO_LDFLAGS="-ldl"`
   - **Security Policies**: Check `dmesg | grep DENIED` for SELinux/AppArmor blocks

5. **Extreme option**: Bake the extension directly into the binary:
   ```go
   // #cgo CFLAGS: -DSQLITE_ENABLE_LOAD_EXTENSION
   // #include "myextension.c"
   import "C"
   ```