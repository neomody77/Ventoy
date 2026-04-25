#!/bin/bash
# Ventoy2Disk_macOS.sh
# Port of Ventoy2Disk.sh for macOS (Intel + Apple Silicon)
#
# Usage:
#   sudo ./Ventoy2Disk_macOS.sh -l                  # list candidate disks
#   sudo ./Ventoy2Disk_macOS.sh -i /dev/diskN       # install (DESTRUCTIVE)
#   sudo ./Ventoy2Disk_macOS.sh -u /dev/diskN       # update (keeps data)
#
# Environment overrides:
#   VTOY_FORCE=1        skip the "this will wipe" interactive confirm
#   VTOY_FS=exfat       data partition filesystem: exfat|fat32 (default exfat)
#   VTOY_RESERVE_MB=N   reserve N MiB at tail (default 0)

set -e
set -u

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "[+] $*"; }
warn() { echo "[!] $*" >&2; }

# Resolve script dir (the INSTALL/ tree layout must stay intact)
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

# ---- Constants that must match ventoy_lib.sh ----
VENTOY_SECTOR_SIZE=512
VENTOY_SECTOR_NUM=65536        # 32 MiB VTOYEFI partition
VTOY_FS="${VTOY_FS:-exfat}"
VTOY_RESERVE_MB="${VTOY_RESERVE_MB:-0}"

# ---- Locate tools shipped with Ventoy ----
case "$(uname -m)" in
    arm64)  TOOL_ARCH=mac ;;
    x86_64) TOOL_ARCH=mac ;;
    *) die "Unsupported macOS arch: $(uname -m)" ;;
esac
VTOYCLI="$SCRIPT_DIR/tool/$TOOL_ARCH/vtoycli"
[ -x "$VTOYCLI" ] || die "vtoycli not found at $VTOYCLI (run vtoycli/build_macos.sh first)"

BOOT_IMG="$SCRIPT_DIR/boot/boot.img"
CORE_IMG="$SCRIPT_DIR/boot/core.img.xz"
VTOYEFI_IMG="$SCRIPT_DIR/ventoy/ventoy.disk.img.xz"
[ -f "$BOOT_IMG" ]   || die "missing $BOOT_IMG (did you extract a Ventoy release tarball here?)"
[ -f "$CORE_IMG" ]   || die "missing $CORE_IMG"
[ -f "$VTOYEFI_IMG" ] || die "missing $VTOYEFI_IMG"

# ---- Action: list candidate external disks ----
cmd_list() {
    echo "Candidate removable disks:"
    echo ""
    diskutil list external physical | grep -E '^/dev/disk' | while read -r line; do
        dev=$(echo "$line" | awk '{print $1}')
        size=$(diskutil info "$dev" | awk -F: '/Disk Size/{print $2; exit}' | xargs)
        name=$(diskutil info "$dev" | awk -F: '/Device \/ Media Name/{print $2; exit}' | xargs)
        proto=$(diskutil info "$dev" | awk -F: '/Protocol/{print $2; exit}' | xargs)
        removable=$(diskutil info "$dev" | awk -F: '/Removable Media/{print $2; exit}' | xargs)
        echo "  $dev"
        echo "      Name:      $name"
        echo "      Size:      $size"
        echo "      Protocol:  $proto"
        echo "      Removable: $removable"
        echo ""
    done
    echo "Internal/system disks are EXCLUDED automatically."
    echo "Use: sudo $0 -i <disk>   to install (will ERASE the disk)"
}

# ---- Safety: ensure target disk is external+physical and not the system volume ----
check_target_disk_safe() {
    local disk="$1"
    [[ "$disk" =~ ^/dev/disk[0-9]+$ ]] || die "expected /dev/diskN, got: $disk"
    diskutil info "$disk" > /dev/null 2>&1 || die "disk $disk does not exist"

    # Only reject if explicitly marked Internal: Yes; disk images don't
    # have this field at all, which is fine.
    local internal
    internal=$(diskutil info "$disk" | awk -F: '/Internal:/{print $2; exit}' | xargs)
    [ "$internal" != "Yes" ] || die "REFUSING: $disk is an INTERNAL disk"

    local proto
    proto=$(diskutil info "$disk" | awk -F: '/Protocol/{print $2; exit}' | xargs)
    case "$proto" in
        USB|Thunderbolt|"USB 3"*|"USB 2"*) : ;;
        "Disk Image")
            if [ "${VTOY_ALLOW_IMG:-0}" = "1" ]; then
                warn "accepting disk image $disk because VTOY_ALLOW_IMG=1 (DRY-RUN MODE)"
            else
                die "REFUSING: $disk is a Disk Image (set VTOY_ALLOW_IMG=1 for dry-run)"
            fi
            ;;
        *) die "REFUSING: $disk protocol '$proto' is not USB/Thunderbolt" ;;
    esac

    # Make sure we're not the disk /System/Volumes/Data lives on
    local root_dev
    root_dev=$(df -h / | awk 'NR==2{print $1}')
    [ "$disk" != "${root_dev%s*}" ] || die "REFUSING: $disk hosts the root filesystem"
}

confirm_destruction() {
    local disk="$1"
    if [ "${VTOY_FORCE:-0}" = "1" ]; then
        warn "VTOY_FORCE=1, skipping interactive confirm"
        return
    fi
    local size name
    size=$(diskutil info "$disk" | awk -F: '/Disk Size/{print $2; exit}' | xargs)
    name=$(diskutil info "$disk" | awk -F: '/Device \/ Media Name/{print $2; exit}' | xargs)
    echo ""
    echo "================================================================"
    echo "  WARNING: ALL DATA ON $disk WILL BE LOST"
    echo "    Device: $name"
    echo "    Size:   $size"
    echo "================================================================"
    read -p "Type YES to continue: " answer
    [ "$answer" = "YES" ] || die "aborted"
}

# ---- Disk size (bytes) via our macOS-ported vtoycli wouldn't expose this
#      directly, so use diskutil, which is also how we identified the disk ----
get_disk_size_bytes() {
    diskutil info "$1" | awk -F '[()]' '/Disk Size/ {print $2; exit}' | awk '{print $1}'
}

# ---- Unmount all partitions of the disk so we can do raw writes ----
unmount_disk() {
    local disk="$1"
    info "unmounting $disk (and any mounted partitions) ..."
    diskutil unmountDisk force "$disk" > /dev/null || true
}

# ---- Partition layout (MBR/MSDOS) ----
compute_partition_layout() {
    local total_sectors="$1"
    local reserve_sectors=$((VTOY_RESERVE_MB * 2048))

    PART1_START=2048
    if [ "$reserve_sectors" -gt 0 ]; then
        PART1_END=$((total_sectors - reserve_sectors - VENTOY_SECTOR_NUM - 1))
    else
        PART1_END=$((total_sectors - VENTOY_SECTOR_NUM - 1))
    fi
    PART2_START=$((PART1_END + 1))
    # 4KiB align part2 start
    local mod=$((PART2_START % 8))
    if [ "$mod" -gt 0 ]; then
        PART1_END=$((PART1_END - mod))
        PART2_START=$((PART1_END + 1))
    fi
    PART2_END=$((PART2_START + VENTOY_SECTOR_NUM - 1))
}

# ---- MBR partition type byte for the data partition ----
get_part1_type() {
    case "$VTOY_FS" in
        exfat|ntfs) echo 0x07 ;;
        fat32)      echo 0x0c ;;  # FAT32 LBA — required for macOS auto-mount
        *)          echo 0x07 ;;
    esac
}

# ---- Write combined MBR sector 0: bootstrap (0..445) + partition table (446..509) + 0x55AA ----
#      On macOS, raw-device writes must be sector-aligned. We build the full
#      512-byte MBR in memory (446 bytes of Ventoy's boot.img + our partition
#      entries) and write it as a single sector.
write_mbr_sector() {
    local rdev="$1"
    local p1type
    p1type=$(get_part1_type)
    info "writing MBR sector (boot.img bootstrap + partition table, P1 type=$p1type) to $rdev ..."
    python3 - "$rdev" "$BOOT_IMG" "$PART1_START" "$PART1_END" "$PART2_START" "$PART2_END" "$p1type" <<'PY'
import os, struct, sys
rdev, boot_img = sys.argv[1], sys.argv[2]
p1s, p1e, p2s, p2e = map(int, sys.argv[3:7])
p1_type = int(sys.argv[7], 0)  # accepts 0x07 / 0x0c

# Build sector 0 from scratch — never read from rdev (macOS raw-device caching
# can corrupt read-modify-write on a fresh device).
sector = bytearray(b"\x00" * 512)

with open(boot_img, "rb") as f:
    bootstrap = f.read(446)
if len(bootstrap) != 446:
    raise SystemExit("boot.img shorter than 446 bytes: %d" % len(bootstrap))
sector[0:446] = bootstrap

# Ventoy disk UUID: 16 random bytes at offset 384 (0x180) — replaces the
# 16-byte 'X' placeholder baked into boot.img. Matches Linux installer
# line `dd seek=384 bs=1 count=16` with random data.
with open("/dev/urandom", "rb") as u:
    vtoy_uuid = u.read(16)
sector[384:400] = vtoy_uuid

# Standard MBR disk signature: 4 bytes at offset 440 (0x1B8).
# Official Linux takes bytes 12..15 from a fresh UUID (skip=12, count=4).
with open("/dev/urandom", "rb") as u:
    disk_sig = u.read(4)
sector[440:444] = disk_sig

def entry(boot, typ, start, end):
    return struct.pack(
        "<B3sB3sII",
        boot, b"\x00\x00\x00", typ, b"\x00\x00\x00",
        start, end - start + 1,
    )

table = (
    entry(0x80, p1_type, p1s, p1e) # P1 (boot flag set): 0x07 exFAT/NTFS, 0x0c FAT32 LBA
    + entry(0x00, 0xEF, p2s, p2e)  # P2: FAT16 EFI
    + b"\x00" * 32
)
assert len(table) == 64
sector[446:510] = table
sector[510:512] = b"\x55\xAA"

# Write-only open, so there's no leftover read position / cache interference.
# On /dev/rdiskN we must write whole sectors only.
fd = os.open(rdev, os.O_WRONLY)
try:
    os.lseek(fd, 0, os.SEEK_SET)
    n = os.write(fd, bytes(sector))
    if n != 512:
        raise SystemExit("short write: %d/512" % n)
    os.fsync(fd)
finally:
    os.close(fd)

print("  sector 0 written (bootstrap %d B + partition table 64 B + signature)"
      % len(bootstrap))
PY
}

# ---- Write GRUB2 core.img into sectors 1..2047 (MBR layout) ----
write_core_img() {
    local rdev="$1"
    info "writing core.img to sectors 1..2047 ..."
    xz -d -c "$CORE_IMG" | dd of="$rdev" bs=512 count=2047 seek=1 conv=sync status=none
}

# ---- Write pre-built ventoy.disk.img to partition 2 ----
#      This image is a complete 32MiB FAT16 filesystem with grub.cfg, .efi
#      bootloaders, etc. baked in. Replaces the whole "format + populate"
#      song and dance the Linux script does not need.
write_vtoyefi_image() {
    local rdev="$1"
    local vtoy_img="$SCRIPT_DIR/ventoy/ventoy.disk.img.xz"
    [ -f "$vtoy_img" ] || die "missing $vtoy_img"
    info "writing VTOYEFI image to sectors $PART2_START..$PART2_END ..."
    xz -d -c "$vtoy_img" | dd of="$rdev" bs=512 count="$VENTOY_SECTOR_NUM" seek="$PART2_START" conv=sync status=none
}

# ---- Format partition 1 (data) ----
format_part1() {
    local part1="$1"
    # Wipe first 4MiB so any residual exFAT/NTFS magic doesn't trick newfs
    # or macOS auto-mount into thinking the old fs is still there.
    info "wiping first 4MiB of $part1 ..."
    dd if=/dev/zero of="$part1" bs=1m count=4 conv=sync 2>/dev/null || true
    if [ "$VTOY_FS" = "exfat" ]; then
        info "creating exFAT on $part1 ..."
        newfs_exfat -v Ventoy "$part1"
    elif [ "$VTOY_FS" = "fat32" ]; then
        info "creating FAT32 on $part1 ..."
        newfs_msdos -F 32 -v VENTOY "$part1"
    else
        die "unsupported VTOY_FS=$VTOY_FS"
    fi
}

# ---- Main install flow ----
cmd_install() {
    local disk="$1"
    local rdisk="${disk/disk/rdisk}"   # /dev/disk6 -> /dev/rdisk6 (raw, fast)

    check_target_disk_safe "$disk"
    confirm_destruction "$disk"

    local total_sectors
    total_sectors=$("$VTOYCLI" fat -s "$disk" 2>/dev/null || true)
    # Fallback: read from diskutil since vtoycli 'fat -s' is FAT-specific
    if ! [[ "$total_sectors" =~ ^[0-9]+$ ]]; then
        local bytes
        bytes=$(diskutil info "$disk" | awk -F '[()]' '/Disk Size/ {print $2; exit}' | awk '{print $1}')
        total_sectors=$((bytes / VENTOY_SECTOR_SIZE))
    fi
    info "disk total sectors: $total_sectors"

    compute_partition_layout "$total_sectors"
    info "partition layout:"
    info "  P1 data   sectors $PART1_START .. $PART1_END  ($(((PART1_END-PART1_START+1)*512/1024/1024)) MiB)"
    info "  P2 efi    sectors $PART2_START .. $PART2_END  ($(((PART2_END-PART2_START+1)*512/1024/1024)) MiB)"

    unmount_disk "$disk"

    write_mbr_sector "$rdisk"
    write_core_img "$rdisk"
    write_vtoyefi_image "$rdisk"

    # Nudge the kernel to re-read the partition table. On macOS the standard
    # way is to detach+reattach the whole disk via diskutil.
    info "forcing partition table reload ..."
    diskutil unmountDisk force "$disk" > /dev/null || true
    # The kernel should pick up the new layout via IOKit; if not, eject+replug.
    sleep 1

    # Wait for partitions to appear
    for i in $(seq 1 10); do
        if [ -e "${disk}s1" ] && [ -e "${disk}s2" ]; then break; fi
        sleep 1
    done
    [ -e "${disk}s1" ] || die "partition ${disk}s1 did not appear (try ejecting and re-plugging)"
    [ -e "${disk}s2" ] || die "partition ${disk}s2 did not appear"

    format_part1 "${disk}s1"
    # partition 2 already contains the VTOYEFI image, no further formatting

    info "syncing and ejecting ..."
    sync
    diskutil eject "$disk" > /dev/null || true
    echo ""
    echo "DONE. You can now copy ISO files into the 'Ventoy' partition."
}

# ---- CLI ----
case "${1:-}" in
    -l|list|--list)
        cmd_list
        ;;
    -i|install|--install)
        [ $# -ge 2 ] || die "usage: sudo $0 -i /dev/diskN"
        [ "$(id -u)" = "0" ] || die "install requires sudo"
        cmd_install "$2"
        ;;
    *)
        cat <<USAGE
Ventoy2Disk_macOS.sh - install Ventoy onto a USB/Thunderbolt drive on macOS

Usage:
  sudo $0 -l                    list candidate external drives
  sudo $0 -i /dev/diskN         install (WIPES the disk)

Environment:
  VTOY_FORCE=1                  skip interactive "YES" confirm
  VTOY_FS=exfat|fat32           data partition filesystem (default: exfat)
  VTOY_RESERVE_MB=N             leave N MiB unallocated at tail
USAGE
        exit 1
        ;;
esac
