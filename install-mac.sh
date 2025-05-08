curl -L https://github.com/JonUdell/xmlui-test-server/releases/download/v0.0.1/xmlui-test-server-mac-arm.tar.gz | tar -xz && \
chmod +x xmlui-test-server-mac-arm && \
xattr -d com.apple.quarantine xmlui-test-server-mac-arm 2>/dev/null || true
