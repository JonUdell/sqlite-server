module xmlui-test-server

go 1.21.4

require (
	github.com/lib/pq v1.10.9
	github.com/mattn/go-sqlite3 v1.14.28
)

replace github.com/mattn/go-sqlite3 => ../go-sqlite3
