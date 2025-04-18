wget https://www.sqlite.org/2024/sqlite-autoconf-3450200.tar.gz
tar xzf sqlite-autoconf-3450200.tar.gz
cd sqlite-autoconf-3450200

make clean
./configure --disable-shared --enable-static
make

export CFLAGS="-DSQLITE_ENABLE_LOAD_EXTENSION -DSQLITE_ALLOW_LOAD_EXTENSION"
make CFLAGS="$CFLAGS"
make install

CGO_ENABLED=1 CGO_CFLAGS="-I$HOME/sqlite/sqlite-autoconf-3450200/include" CGO_LDFLAGS="$HOME/sqlite/sqlite-autoconf-3450200/.libs/libsqlite3.a -lm -ldl" go build -tags "sqlite3_load_extension" -v
