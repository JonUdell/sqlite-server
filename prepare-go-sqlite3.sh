#!/usr/bin/env bash
set -euo pipefail

echo "🔧 Preparing patched go-sqlite3 driver..."

# Clone fresh every time to avoid dirty state
rm -rf $HOME/go-sqlite3
git clone https://github.com/mattn/go-sqlite3.git $HOME/go-sqlite3

# Verify the patch target exists
if ! grep -q 'if db == nil {' $HOME/go-sqlite3/sqlite3.go; then
  echo "❌ Error: Could not find 'if db == nil {' in sqlite3.go. Upstream may have changed." >&2
  exit 1
fi

# Patch: insert extension enabling
sed -i '/if db == nil {/a C.sqlite3_enable_load_extension(db, 1);' $HOME/go-sqlite3/sqlite3.go

# Verify patch success
if ! grep -q 'C.sqlite3_enable_load_extension(db, 1);' $HOME/go-sqlite3/sqlite3.go; then
  echo "❌ Error: Patch failed. Extension enabling code not inserted." >&2
  exit 1
fi

# Force update go.mod to point to patched driver
go mod edit -dropreplace github.com/mattn/go-sqlite3 || true
go mod edit -replace github.com/mattn/go-sqlite3=$HOME/go-sqlite3
go mod tidy

echo "✅ go-sqlite3 patched and ready."
