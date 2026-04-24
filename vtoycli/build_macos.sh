#!/bin/sh
# Build vtoycli for macOS (universal2: x86_64 + arm64)
set -e

rm -f vtoycli_arm64 vtoycli_x86_64 vtoycli_mac

# fat_io_lib has no prebuilt macOS .a, so compile its sources inline
SRCS="vtoycli.c vtoyfat.c vtoygpt.c crc32.c partresize.c
      fat_io_lib/release/fat_access.c
      fat_io_lib/release/fat_cache.c
      fat_io_lib/release/fat_filelib.c
      fat_io_lib/release/fat_format.c
      fat_io_lib/release/fat_misc.c
      fat_io_lib/release/fat_string.c
      fat_io_lib/release/fat_table.c
      fat_io_lib/release/fat_write.c"

CFLAGS="-Os -D_FILE_OFFSET_BITS=64 -Ifat_io_lib/include -Wno-unused-result -Wno-pointer-sign -Wno-error=implicit-function-declaration -Wno-implicit-function-declaration"

# Build per-arch then lipo into universal2
clang $CFLAGS -arch arm64  $SRCS -o vtoycli_arm64
clang $CFLAGS -arch x86_64 $SRCS -o vtoycli_x86_64
lipo -create vtoycli_arm64 vtoycli_x86_64 -output vtoycli_mac

rm -f vtoycli_arm64 vtoycli_x86_64
strip vtoycli_mac

echo "---"
file vtoycli_mac
ls -la vtoycli_mac

# Install into INSTALL/tool/mac/ if that tree exists
if [ -d ../INSTALL/tool ]; then
    mkdir -p ../INSTALL/tool/mac
    cp vtoycli_mac ../INSTALL/tool/mac/vtoycli
    echo "installed to ../INSTALL/tool/mac/vtoycli"
fi
