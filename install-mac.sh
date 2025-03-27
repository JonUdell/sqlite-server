curl -L https://github.com/JonUdell/sqlite-server/releases/download/v0.0.1/sqlite-server-mac-arm.tar.gz | tar -xz && \
chmod +x sqlite-server-mac-arm && \
xattr -d com.apple.quarantine sqlite-server-mac-arm 2>/dev/null || true
