#!/bin/bash

# ============================================================
# SNAPACK Firmware Archive / Flash / Restore Utility
# ============================================================

set -e

BUILD_DIR="/home/valued/Arduino/snapack/build/esp32.esp32.esp32s3"
ARCHIVE_DIR="/home/valued/Arduino/snapack/archive/bin_backup"

BOOT_APP0="/home/valued/.arduino15/packages/esp32/hardware/esp32/2.0.14/tools/partitions/boot_app0.bin"

ESPTOOL="$HOME/.local/bin/esptool"
PORT="/dev/ttyACM0"

STATE_FILE="$ARCHIVE_DIR/.last_flash"

mkdir -p "$ARCHIVE_DIR"


flash_directory()
{
    DIR="$1"

    echo
    echo "Flashing:"
    echo "  $DIR"
    echo

    "$ESPTOOL" \
        --no-stub \
        --chip esp32s3 \
        --port "$PORT" \
        write-flash \
        --flash-mode dio \
        --flash-freq 80m \
        --flash-size 16MB \
        0x0000  "$DIR/snapack.ino.bootloader.bin" \
        0x8000  "$DIR/snapack.ino.partitions.bin" \
        0xe000  "$DIR/boot_app0.bin" \
        0x10000 "$DIR/snapack.ino.bin"
}


# ============================================================
# CHECK PREVIOUS FLASH
# ============================================================

if [[ -f "$STATE_FILE" ]]; then

    LAST_ARCHIVE=$(cat "$STATE_FILE")

    if [[ -d "$LAST_ARCHIVE" ]]; then

        CURRENT_STATUS="UNKNOWN"

        if [[ -f "$LAST_ARCHIVE/STATUS" ]]; then
            CURRENT_STATUS=$(cat "$LAST_ARCHIVE/STATUS")
        fi

        if [[ "$CURRENT_STATUS" == "PENDING" ]]; then

            echo
            echo "Previous flashed version:"
            echo "  $(basename "$LAST_ARCHIVE")"
            echo

            read -r -p "Was the previous flash successful? [Y/n]: " ANSWER
            ANSWER=${ANSWER:-Y}

            if [[ "$ANSWER" =~ ^[Yy]$ ]]; then
                echo "GOOD" > "$LAST_ARCHIVE/STATUS"
                echo "Previous version marked GOOD."
            else
                echo "BAD" > "$LAST_ARCHIVE/STATUS"
                echo "Previous version marked BAD."
            fi
        fi
    fi
fi


# ============================================================
# MAIN MENU
# ============================================================

echo
echo "=========================================="
echo " SNAPACK Firmware Utility"
echo "=========================================="
echo
echo "1) Archive and flash newest Arduino build"
echo "2) Restore archived firmware"
echo "3) List firmware archive"
echo "4) Exit"
echo

read -r -p "Select: " CHOICE


case "$CHOICE" in

# ============================================================
# ARCHIVE + FLASH NEW BUILD
# ============================================================

1)

    REQUIRED_FILES=(
        "$BUILD_DIR/snapack.ino.bootloader.bin"
        "$BUILD_DIR/snapack.ino.partitions.bin"
        "$BUILD_DIR/snapack.ino.bin"
        "$BOOT_APP0"
    )

    for FILE in "${REQUIRED_FILES[@]}"; do
        if [[ ! -f "$FILE" ]]; then
            echo
            echo "ERROR: Required file missing:"
            echo "  $FILE"
            exit 1
        fi
    done

    TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
    NEW_ARCHIVE="$ARCHIVE_DIR/$TIMESTAMP"

    mkdir -p "$NEW_ARCHIVE"

    echo
    echo "Archiving new firmware BEFORE flashing..."

    cp "$BUILD_DIR/snapack.ino.bootloader.bin" \
       "$NEW_ARCHIVE/"

    cp "$BUILD_DIR/snapack.ino.partitions.bin" \
       "$NEW_ARCHIVE/"

    cp "$BUILD_DIR/snapack.ino.bin" \
       "$NEW_ARCHIVE/"

    cp "$BOOT_APP0" \
       "$NEW_ARCHIVE/boot_app0.bin"

    echo "PENDING" > "$NEW_ARCHIVE/STATUS"

    {
        echo "SNAPACK firmware archive"
        echo "Created: $(date)"
        echo
        echo "Original build directory:"
        echo "$BUILD_DIR"
        echo
        echo "ESP32 Arduino core boot_app0 source:"
        echo "$BOOT_APP0"
        echo
        echo "Flash parameters:"
        echo "chip=esp32s3"
        echo "port=$PORT"
        echo "flash_mode=dio"
        echo "flash_freq=80m"
        echo "flash_size=16MB"
        echo
        echo "Addresses:"
        echo "0x0000  snapack.ino.bootloader.bin"
        echo "0x8000  snapack.ino.partitions.bin"
        echo "0xe000  boot_app0.bin"
        echo "0x10000 snapack.ino.bin"
    } > "$NEW_ARCHIVE/INFO.txt"

    echo "$NEW_ARCHIVE" > "$STATE_FILE"

    echo
    echo "Archive created:"
    echo "  $NEW_ARCHIVE"

    # Flash the archived copies themselves.
    flash_directory "$NEW_ARCHIVE"

    echo
    echo "Flash completed."
    echo
    echo "This version remains PENDING."
    echo "Its GOOD/BAD status will be asked the next time"
    echo "the utility is run."
    ;;


# ============================================================
# RESTORE ARCHIVED FIRMWARE
# ============================================================

2)

    mapfile -t ARCHIVES < <(
        find "$ARCHIVE_DIR" \
            -mindepth 1 \
            -maxdepth 1 \
            -type d \
            | sort -r
    )

    if [[ ${#ARCHIVES[@]} -eq 0 ]]; then
        echo
        echo "No archived firmware found."
        exit 0
    fi

    echo
    echo "Available archived firmware:"
    echo

    for i in "${!ARCHIVES[@]}"; do

        STATUS="UNKNOWN"

        if [[ -f "${ARCHIVES[$i]}/STATUS" ]]; then
            STATUS=$(cat "${ARCHIVES[$i]}/STATUS")
        fi

        printf "%3d) %-22s [%s]\n" \
            "$((i + 1))" \
            "$(basename "${ARCHIVES[$i]}")" \
            "$STATUS"
    done

    echo
    read -r -p "Select archive to restore: " NUMBER

    if ! [[ "$NUMBER" =~ ^[0-9]+$ ]]; then
        echo "Invalid selection."
        exit 1
    fi

    INDEX=$((NUMBER - 1))

    if (( INDEX < 0 || INDEX >= ${#ARCHIVES[@]} )); then
        echo "Invalid selection."
        exit 1
    fi

    SELECTED="${ARCHIVES[$INDEX]}"

    REQUIRED_ARCHIVE_FILES=(
        "$SELECTED/snapack.ino.bootloader.bin"
        "$SELECTED/snapack.ino.partitions.bin"
        "$SELECTED/boot_app0.bin"
        "$SELECTED/snapack.ino.bin"
    )

    for FILE in "${REQUIRED_ARCHIVE_FILES[@]}"; do
        if [[ ! -f "$FILE" ]]; then
            echo
            echo "ERROR: Archive is incomplete."
            echo "Missing:"
            echo "  $FILE"
            exit 1
        fi
    done

    echo
    echo "Selected:"
    echo "  $(basename "$SELECTED")"

    if [[ -f "$SELECTED/STATUS" ]]; then
        echo "Status:"
        echo "  $(cat "$SELECTED/STATUS")"
    fi

    echo
    read -r -p "Flash this archived version? [y/N]: " CONFIRM

    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo "Restore cancelled."
        exit 0
    fi

    flash_directory "$SELECTED"

    # This is now what is physically installed.
    echo "$SELECTED" > "$STATE_FILE"

    echo
    echo "Restore completed."
    ;;


# ============================================================
# LIST ARCHIVE
# ============================================================

3)

    echo
    echo "SNAPACK firmware archive:"
    echo

    FOUND=0

    for DIR in "$ARCHIVE_DIR"/*/; do

        [[ -d "$DIR" ]] || continue
        FOUND=1

        STATUS="UNKNOWN"

        if [[ -f "$DIR/STATUS" ]]; then
            STATUS=$(cat "$DIR/STATUS")
        fi

        printf "%-22s [%s]\n" \
            "$(basename "$DIR")" \
            "$STATUS"
    done

    if [[ "$FOUND" -eq 0 ]]; then
        echo "No archived firmware found."
    fi
    ;;


4)
    exit 0
    ;;


*)
    echo "Invalid selection."
    exit 1
    ;;

esac
