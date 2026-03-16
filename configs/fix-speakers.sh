#!/bin/bash
set -euo pipefail

# Fix CS35L56 speaker amplifier firmware for ASUS ROG Zephyrus G16 (2025)
# Subsystem ID 10431034 firmware is not yet in linux-firmware.
# Symlink to 10431044 (similar ASUS model) which works.

FW_DIR="/lib/firmware/cirrus"
SOURCE_ID="10431044"
TARGET_ID="10431034"

SYMLINKS=(
    "cs35l56-b0-dsp1-misc-${TARGET_ID}-spkid0-amp1.bin:cs35l56-b0-dsp1-misc-${SOURCE_ID}-spkid0-amp1.bin"
    "cs35l56-b0-dsp1-misc-${TARGET_ID}-spkid0-amp2.bin:cs35l56-b0-dsp1-misc-${SOURCE_ID}-spkid0-amp2.bin"
    "cs35l56-b0-dsp1-misc-${TARGET_ID}-spkid0.wmfw:cs35l56-b0-dsp1-misc-${SOURCE_ID}-spkid0.wmfw"
    "cs35l56-b0-dsp1-misc-${TARGET_ID}-spkid1-amp1.bin:cs35l56-b0-dsp1-misc-${SOURCE_ID}-spkid1-amp1.bin"
    "cs35l56-b0-dsp1-misc-${TARGET_ID}-spkid1-amp2.bin:cs35l56-b0-dsp1-misc-${SOURCE_ID}-spkid1-amp2.bin"
    "cs35l56-b0-dsp1-misc-${TARGET_ID}-spkid1.wmfw:cs35l56-b0-dsp1-misc-${SOURCE_ID}-spkid1.wmfw"
)

if [[ $EUID -ne 0 ]]; then
    echo "Run with sudo"
    exit 1
fi

if [[ ! -d "$FW_DIR" ]]; then
    echo "Firmware directory $FW_DIR not found"
    exit 1
fi

# Verify source firmware exists
if [[ ! -f "$FW_DIR/cs35l56-b0-dsp1-misc-${SOURCE_ID}-spkid0-amp1.bin" ]]; then
    echo "Source firmware for $SOURCE_ID not found in $FW_DIR"
    echo "You may need to update linux-firmware first: sudo apt update && sudo apt install linux-firmware"
    exit 1
fi

CREATED=0
for entry in "${SYMLINKS[@]}"; do
    link="${entry%%:*}"
    target="${entry##*:}"

    if [[ -e "$FW_DIR/$link" ]]; then
        echo "[ok] $link already exists"
    else
        ln -s "$target" "$FW_DIR/$link"
        echo "[+]  Created $link -> $target"
        ((CREATED++))
    fi
done

if [[ $CREATED -gt 0 ]]; then
    echo ""
    echo "$CREATED symlinks created. Reboot for speakers to work."
else
    echo ""
    echo "All symlinks already in place."
fi
