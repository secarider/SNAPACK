#!/bin/bash

# =========================================================================================
# SNAPACK FIRMWARE ARCHIVE / FLASH / RESTORE UTILITY
# =========================================================================================
# PURPOSE:
# - Archive every newly exported SNAPACK firmware build BEFORE it is flashed.
# - Keep the exact four-file ESP32-S3 flash set together as one restorable unit.
# - Remember which archived version was flashed most recently.
# - Ask on the next run whether that flash proved GOOD or BAD in physical testing.
# - Restore any retained archive without rebuilding old source code.
#
# WORKFLOW PHILOSOPHY:
# - The archive copy is the authority for the flash operation.
# - A version is PENDING until the next run confirms whether it behaved correctly.
# - BAD means "known bad in physical testing"; it is retained, not silently deleted.
# - Restores flash the archived binaries exactly as they were preserved.
#
# IMPORTANT:
# - This utility does NOT compile SNAPACK firmware.
# - Arduino IDE "Export Compiled Binary" produces the build this utility archives.
# - The utility then flashes the archived copy with esptool.
# =========================================================================================

set -e

# =========================================================================================
# MARKER: COLOR DEFINITIONS
# =========================================================================================
# HOUSE COLOR RULE:
# - GREEN / GR  = success / known good
# - YELLOW / YE = caution / pending / user attention
# - RED / RE    = error / known bad / destructive warning
# - CYAN / CY   = structure / headings / informational labels
# - WHITE / BW  = neutral emphasis
# =========================================================================================

RED=$'\033[1;31m'
RE=$'\033[1;31m'
REB=$'\033[5;31m'

GREEN=$'\033[1;32m'
GR=$'\033[1;32m'

YELLOW=$'\033[1;33m'
YE=$'\033[1;33m'
YEB=$'\033[5;33m'

CYAN=$'\033[1;36m'
CY=$'\033[1;36m'

WHITE=$'\033[1;37m'
BW=$'\033[1;37m'

GRAY=$'\033[0;37m'
DIM=$'\033[2m'
NC=$'\033[0m'

# =========================================================================================
# MARKER: PATHS / FLASH CONSTANTS
# =========================================================================================
# BUILD_DIR:
# - Arduino IDE export/build output currently used by SNAPACK.
#
# ARCHIVE_DIR:
# - Permanent timestamped firmware archive.
#
# BOOT_APP0:
# - Arduino ESP32 core boot_app0 binary required for the established flash layout.
#
# ESPTOOL / PORT:
# - Known working command-line esptool path and SNAPACK USB serial device.
# =========================================================================================

BUILD_DIR="/home/valued/Arduino/snapack/build/esp32.esp32.esp32s3"
ARCHIVE_DIR="/home/valued/Arduino/snapack/archive/bin_backup"
IMAGE_ARCHIVE_DIR="/home/valued/Arduino/snapack/archive/device_images"

BOOT_APP0="/home/valued/.arduino15/packages/esp32/hardware/esp32/2.0.14/tools/partitions/boot_app0.bin"

ESPTOOL="$HOME/.local/bin/esptool"
PORT="/dev/ttyACM0"

STATE_FILE="$ARCHIVE_DIR/.last_flash"

FULL_FLASH_SIZE_HEX="0x1000000"
FULL_FLASH_SIZE_BYTES=16777216

mkdir -p "$ARCHIVE_DIR"
mkdir -p "$IMAGE_ARCHIVE_DIR"

# =========================================================================================
# MARKER: DISPLAY HELPERS
# =========================================================================================

print_rule() {
    echo -e "${CYAN}==========================================================================${NC}"
}

print_header() {
    local title="$1"
    echo
    print_rule
    echo -e "${CYAN}          ${title}${NC}"
    print_rule
    echo
}

print_info() {
    echo -e "${CY} = = >${NC} $*"
}

print_good() {
    echo -e "${GR} = = > $*${NC}"
}

print_warn() {
    echo -e "${YE} = = > $*${NC}"
}

print_error() {
    echo -e "${RE} = = > ERROR:${NC} ${YELLOW}$*${NC}" >&2
}

pause_screen() {
    local prompt="${1:-Press Enter To Continue...}"
    echo
    echo -ne "${CYAN} = = >${NC} ${YELLOW}${prompt}${NC}"
    read -r _PAUSE_INPUT
}

# Return a colored human-readable status without changing the STATUS file itself.
format_status() {
    local status="${1:-UNKNOWN}"

    case "$status" in
        GOOD)
            printf '%sGOOD%s' "$GR" "$NC"
            ;;
        BAD)
            printf '%sBAD%s' "$RE" "$NC"
            ;;
        PENDING)
            printf '%sPENDING%s' "$YE" "$NC"
            ;;
        *)
            printf '%s%s%s' "$GRAY" "$status" "$NC"
            ;;
    esac
}

# =========================================================================================
# MARKER: FIRMWARE ARCHIVE INTEGRITY
# =========================================================================================
# PURPOSE:
# - Every flashable archive is self-validating.
# - SHA256SUMS is created only when a new archive is built from verified copies.
# - Existing archives are NEVER silently given new hashes during restore.
# - Every path into esptool passes through verify_firmware_archive().
# =========================================================================================

FIRMWARE_FILES=(
    "snapack.ino.bootloader.bin"
    "snapack.ino.partitions.bin"
    "boot_app0.bin"
    "snapack.ino.bin"
)

verify_firmware_archive() {
    local dir="$1"
    local file

    print_header "FIRMWARE INTEGRITY CHECK"
    print_info "Archive: ${GREEN}$dir${NC}"

    for file in "${FIRMWARE_FILES[@]}"; do
        if [[ ! -f "$dir/$file" ]]; then
            echo
            print_error "Integrity Check Failed -- Required Firmware File Missing."
            echo -e "${CYAN}       Missing:${NC} ${YELLOW}$file${NC}"
            print_error "FLASH REFUSED."
            return 1
        fi
    done

    if [[ ! -f "$dir/SHA256SUMS" ]]; then
        echo
        print_error "SHA256SUMS Is Missing."
        print_warn "This Archive Is Legacy / Unverified And Will Not Be Flashed."
        print_error "FLASH REFUSED."
        return 1
    fi

    echo
    print_info "Verifying SHA-256 Manifest..."
    echo

    if ! (
        cd "$dir"
        sha256sum -c SHA256SUMS
    ); then
        echo
        print_error "SHA-256 Verification Failed."
        print_error "FLASH REFUSED -- No Firmware Write Was Attempted."
        return 1
    fi

    echo
    print_good "SHA-256 Verification Passed For All Archived Firmware Files."
    return 0
}

# =========================================================================================
# MARKER: FLASH ENGINE
# =========================================================================================
# PURPOSE:
# - Flash one complete archived firmware directory.
# - Keep all established ESP32-S3 addresses and esptool parameters in one place.
#
# DESIGN RULE:
# - Callers pass an archive directory, never a loose individual BIN.
# - New-build flashes and historical restores therefore use the same engine.
# =========================================================================================

flash_directory() {
    local dir="$1"

    # Absolute gate: no caller can reach esptool without a valid archive hash.
    if ! verify_firmware_archive "$dir"; then
        return 1
    fi

    print_header "SNAPACK FLASH ENGINE"
    print_info "Firmware Directory: ${GREEN}$dir${NC}"
    print_info "Target Port:        ${GREEN}$PORT${NC}"
    print_info "Chip:               ${GREEN}ESP32-S3${NC}"
    print_info "Flash Mode:         ${GREEN}DIO / 80 MHz / 16 MB${NC}"
    echo
    echo -e "${YEB} = = > FLASH WRITE STARTING -- DO NOT INTERRUP THE USB CONNECTION.${NC}"
    echo

    "$ESPTOOL" \
        --no-stub \
        --chip esp32s3 \
        --port "$PORT" \
        write-flash \
        --flash-mode dio \
        --flash-freq 80m \
        --flash-size 16MB \
        0x0000  "$dir/snapack.ino.bootloader.bin" \
        0x8000  "$dir/snapack.ino.partitions.bin" \
        0xe000  "$dir/boot_app0.bin" \
        0x10000 "$dir/snapack.ino.bin"

    echo
    print_good "esptool Returned Successfully."
}

# =========================================================================================
# MARKER: FULL DEVICE IMAGE BACKUP
# =========================================================================================
# PURPOSE:
# - Read the complete 16 MB ESP32-S3 flash device into one raw image.
# - Preserve the same low-level recovery capability used for the original
#   Elecrow factory firmware backup.
# - This is a READ-ONLY operation. It does not erase or write the controller.
#
# DESIGN RULE:
# - Raw device images are stored separately from the four-BIN firmware archive.
# - Each captured image gets its own SHA-256 manifest and INFO.txt.
# =========================================================================================

capture_full_flash_image() {
    local timestamp image_dir image_path actual_size

    timestamp=$(date +"%Y-%m-%d_%H-%M-%S")
    image_dir="$IMAGE_ARCHIVE_DIR/$timestamp"
    image_path="$image_dir/snapack_full_flash_16MB.bin"

    print_header "FULL DEVICE IMAGE BACKUP"
    print_info "Proposed Operation:"
    echo -e "${CYAN}       Device:${NC}       ${GREEN}$PORT${NC}"
    echo -e "${CYAN}       Chip:${NC}         ${GREEN}ESP32-S3${NC}"
    echo -e "${CYAN}       Read Range:${NC}   ${GREEN}0x00000000 - 0x00FFFFFF${NC}"
    echo -e "${CYAN}       Image Size:${NC}   ${GREEN}16 MiB${NC}"
    echo -e "${CYAN}       Destination:${NC}  ${GREEN}$image_path${NC}"
    echo
    print_warn "This Operation Reads The Device Only -- It Does Not Erase Or Write Flash."
    print_info "The Completed Image Will Be SHA-256 Protected."
    echo
    pause_screen "Press Enter To Read The Full Device Image, Or Ctrl+C To Cancel..."

    mkdir -p "$image_dir"

    print_header "READING COMPLETE ESP32-S3 FLASH"
    print_info "Destination: ${GREEN}$image_path${NC}"
    echo

    if ! "$ESPTOOL" \
        --no-stub \
        --chip esp32s3 \
        --port "$PORT" \
        read-flash \
        0x0 \
        "$FULL_FLASH_SIZE_HEX" \
        "$image_path"
    then
        echo
        print_error "Device Image Read Failed."
        print_warn "Incomplete Image Folder Will Be Removed."
        rm -rf -- "$image_dir"
        return 1
    fi

    if [[ ! -f "$image_path" ]]; then
        print_error "Expected Device Image Was Not Created."
        rm -rf -- "$image_dir"
        return 1
    fi

    actual_size=$(stat -c '%s' "$image_path")

    if [[ "$actual_size" -ne "$FULL_FLASH_SIZE_BYTES" ]]; then
        echo
        print_error "Device Image Size Check Failed."
        echo -e "${CYAN}       Expected:${NC} ${GREEN}$FULL_FLASH_SIZE_BYTES bytes${NC}"
        echo -e "${CYAN}       Received:${NC} ${YELLOW}$actual_size bytes${NC}"
        print_warn "Incomplete Image Folder Will Be Removed."
        rm -rf -- "$image_dir"
        return 1
    fi

    echo
    print_good "Full 16 MiB Image Captured."

    print_info "Generating SHA-256 Manifest..."
    (
        cd "$image_dir"
        sha256sum snapack_full_flash_16MB.bin > SHA256SUMS
    )

    if ! (
        cd "$image_dir"
        sha256sum -c SHA256SUMS
    ); then
        echo
        print_error "Device Image SHA-256 Verification Failed."
        print_warn "Unverified Image Folder Will Be Removed."
        rm -rf -- "$image_dir"
        return 1
    fi

    {
        echo "SNAPACK full ESP32-S3 flash image"
        echo "Created: $(date)"
        echo
        echo "Source device:"
        echo "$PORT"
        echo
        echo "Read method:"
        echo "$ESPTOOL --no-stub --chip esp32s3 --port $PORT read-flash 0x0 $FULL_FLASH_SIZE_HEX snapack_full_flash_16MB.bin"
        echo
        echo "Image size:"
        echo "$FULL_FLASH_SIZE_BYTES bytes (16 MiB)"
        echo
        echo "Integrity:"
        echo "algorithm=SHA-256"
        echo "manifest=SHA256SUMS"
        echo
        echo "NOTE:"
        echo "This is a raw complete flash-device image, not a four-BIN Arduino firmware archive."
    } > "$image_dir/INFO.txt"

    echo
    print_header "DEVICE IMAGE BACKUP COMPLETE"
    print_good "Full Flash Image Saved And Verified."
    print_info "Image:    ${GREEN}$image_path${NC}"
    print_info "Manifest: ${GREEN}$image_dir/SHA256SUMS${NC}"
    print_info "Info:     ${GREEN}$image_dir/INFO.txt${NC}"

    return 0
}

# =========================================================================================
# MARKER: PREVIOUS FLASH BOOKKEEPING
# =========================================================================================
# PURPOSE:
# - A newly flashed archive is deliberately marked PENDING.
# - On the NEXT run, ask whether physical testing proved that version GOOD or BAD.
# - This keeps firmware judgment separate from the mere fact that esptool completed.
# =========================================================================================

if [[ -f "$STATE_FILE" ]]; then

    LAST_ARCHIVE=$(cat "$STATE_FILE")

    if [[ -d "$LAST_ARCHIVE" ]]; then

        CURRENT_STATUS="UNKNOWN"

        if [[ -f "$LAST_ARCHIVE/STATUS" ]]; then
            CURRENT_STATUS=$(cat "$LAST_ARCHIVE/STATUS")
        fi

        if [[ "$CURRENT_STATUS" == "PENDING" ]]; then

            print_header "PREVIOUS FLASH STATUS CHECK"
            print_info "Previous Flashed Version: ${GREEN}$(basename "$LAST_ARCHIVE")${NC}"
            print_info "Current Archive Status:   $(format_status "$CURRENT_STATUS")"
            echo
            echo -e "${YE} = = > This asks about PHYSICAL / FUNCTIONAL success, not whether esptool ran.${NC}"
            echo

            echo -ne "${YELLOW} = = > Was the previous flash successful? [Y/n]: ${NC}${GREEN}"
            read -r ANSWER
            echo -ne "${NC}"
            ANSWER=${ANSWER:-Y}

            if [[ "$ANSWER" =~ ^[Yy]$ ]]; then
                echo "GOOD" > "$LAST_ARCHIVE/STATUS"
                print_good "Previous Version Marked GOOD: $(basename "$LAST_ARCHIVE")"
            else
                echo "BAD" > "$LAST_ARCHIVE/STATUS"
                print_warn "Previous Version Marked BAD And Retained: $(basename "$LAST_ARCHIVE")"
            fi
        fi
    fi
fi

# =========================================================================================
# MARKER: MAIN MENU
# =========================================================================================

while true; do

print_header "SNAPACK FIRMWARE UTILITY"

echo -e "${YELLOW}     1) Archive And Flash Newest Arduino Build${NC}"
echo -e "${YELLOW}     2) Restore Archived Firmware${NC}"
echo -e "${YELLOW}     3) List Firmware Archive${NC}"
echo -e "${YELLOW}     4) Capture Full 16 MB Device Image${NC}"
echo -e "${YELLOW}     5) Exit${NC}"
echo
echo -e "${CYAN} = = > Build Source:${NC}   ${GREEN}$BUILD_DIR${NC}"
echo -e "${CYAN} = = > Archive Root:${NC}   ${GREEN}$ARCHIVE_DIR${NC}"
echo -e "${CYAN} = = > Image Root:${NC}     ${GREEN}$IMAGE_ARCHIVE_DIR${NC}"
echo -e "${CYAN} = = > Flash Device:${NC}   ${GREEN}$PORT${NC}"
echo

echo -ne "${YELLOW} = = > Select Mission [1-5]: ${NC}${GREEN}"
read -r CHOICE
echo -ne "${NC}"

case "$CHOICE" in

# =========================================================================================
# 1) ARCHIVE + FLASH NEW BUILD
# =========================================================================================

1)
    print_header "ARCHIVE + FLASH NEW BUILD"

    REQUIRED_FILES=(
        "$BUILD_DIR/snapack.ino.bootloader.bin"
        "$BUILD_DIR/snapack.ino.partitions.bin"
        "$BUILD_DIR/snapack.ino.bin"
        "$BOOT_APP0"
    )

    print_info "Checking Required Firmware Components..."

    for FILE in "${REQUIRED_FILES[@]}"; do
        if [[ ! -f "$FILE" ]]; then
            echo
            print_error "Required File Missing"
            echo -e "${CYAN}       Expected:${NC} ${YELLOW}$FILE${NC}"
            echo
            pause_screen
            continue 2
        fi
        echo -e "${GR}       FOUND:${NC} ${GREEN}$FILE${NC}"
    done

    echo
    print_header "READY TO ARCHIVE + FLASH"
    print_info "Proposed Operation:"
    echo -e "${CYAN}       Build Source:${NC} ${GREEN}$BUILD_DIR${NC}"
    echo -e "${CYAN}       Archive Root:${NC} ${GREEN}$ARCHIVE_DIR${NC}"
    echo -e "${CYAN}       Flash Device:${NC} ${GREEN}$PORT${NC}"
    echo -e "${CYAN}       Chip:${NC}         ${GREEN}ESP32-S3${NC}"
    echo
    echo -e "${YE} = = > The Current Arduino Build Will First Be Archived.${NC}"
    echo -e "${YE} = = > The Archived Copies Will Then Be Flashed To The Controller.${NC}"
    echo -e "${YE} = = > No Flash Has Started Yet.${NC}"
    pause_screen "Press Enter To Archive + Flash, Or Ctrl+C To Cancel..."

    TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
    NEW_ARCHIVE="$ARCHIVE_DIR/$TIMESTAMP"

    mkdir -p "$NEW_ARCHIVE"

    echo
    print_warn "Archiving New Firmware BEFORE Flashing."
    print_info "New Archive: ${GREEN}$NEW_ARCHIVE${NC}"
    echo

    cp "$BUILD_DIR/snapack.ino.bootloader.bin" \
       "$NEW_ARCHIVE/"

    cp "$BUILD_DIR/snapack.ino.partitions.bin" \
       "$NEW_ARCHIVE/"

    cp "$BUILD_DIR/snapack.ino.bin" \
       "$NEW_ARCHIVE/"

    cp "$BOOT_APP0" \
       "$NEW_ARCHIVE/boot_app0.bin"

    echo
    print_info "Verifying Archived Copies Against Their Original Sources..."

    COPY_CHECK_FAILED=0

    if cmp -s "$BUILD_DIR/snapack.ino.bootloader.bin" "$NEW_ARCHIVE/snapack.ino.bootloader.bin"; then
        echo -e "${GR}       MATCH:${NC} ${GREEN}snapack.ino.bootloader.bin${NC}"
    else
        print_error "Copy Mismatch: snapack.ino.bootloader.bin"
        COPY_CHECK_FAILED=1
    fi

    if cmp -s "$BUILD_DIR/snapack.ino.partitions.bin" "$NEW_ARCHIVE/snapack.ino.partitions.bin"; then
        echo -e "${GR}       MATCH:${NC} ${GREEN}snapack.ino.partitions.bin${NC}"
    else
        print_error "Copy Mismatch: snapack.ino.partitions.bin"
        COPY_CHECK_FAILED=1
    fi

    if cmp -s "$BOOT_APP0" "$NEW_ARCHIVE/boot_app0.bin"; then
        echo -e "${GR}       MATCH:${NC} ${GREEN}boot_app0.bin${NC}"
    else
        print_error "Copy Mismatch: boot_app0.bin"
        COPY_CHECK_FAILED=1
    fi

    if cmp -s "$BUILD_DIR/snapack.ino.bin" "$NEW_ARCHIVE/snapack.ino.bin"; then
        echo -e "${GR}       MATCH:${NC} ${GREEN}snapack.ino.bin${NC}"
    else
        print_error "Copy Mismatch: snapack.ino.bin"
        COPY_CHECK_FAILED=1
    fi

    if (( COPY_CHECK_FAILED != 0 )); then
        echo
        print_error "Archive Creation Failed."
        print_error "FLASH REFUSED."
        print_warn "Incomplete Archive Will Be Removed; No Normal Archive Was Accepted."
        rm -rf -- "$NEW_ARCHIVE"
        pause_screen
        continue
    fi

    echo
    print_info "Generating SHA-256 Integrity Manifest From Verified Archived Copies..."

    if ! (
        cd "$NEW_ARCHIVE"
        sha256sum \
            snapack.ino.bootloader.bin \
            snapack.ino.partitions.bin \
            boot_app0.bin \
            snapack.ino.bin \
            > SHA256SUMS
    ); then
        echo
        print_error "Could Not Generate SHA256SUMS."
        print_error "FLASH REFUSED."
        rm -rf -- "$NEW_ARCHIVE"
        pause_screen
        continue
    fi

    if ! verify_firmware_archive "$NEW_ARCHIVE"; then
        print_error "New Archive Did Not Pass Its Own Integrity Check."
        print_error "FLASH REFUSED."
        rm -rf -- "$NEW_ARCHIVE"
        pause_screen
        continue
    fi

    echo "PENDING" > "$NEW_ARCHIVE/STATUS"

    # -------------------------------------------------------------------------
    # INFO.txt is intentionally plain text and ANSI-free so every archive is
    # self-describing even when opened outside this utility.
    # -------------------------------------------------------------------------
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
        echo "Integrity:"
        echo "algorithm=SHA-256"
        echo "manifest=SHA256SUMS"
        echo "source_copy_check=cmp -s"
        echo "pre_flash_verification=mandatory"
        echo
        echo "Addresses:"
        echo "0x0000  snapack.ino.bootloader.bin"
        echo "0x8000  snapack.ino.partitions.bin"
        echo "0xe000  boot_app0.bin"
        echo "0x10000 snapack.ino.bin"
    } > "$NEW_ARCHIVE/INFO.txt"

    # This state pointer identifies the version physically flashed most recently.
    echo "$NEW_ARCHIVE" > "$STATE_FILE"

    print_good "Archive Created Before Flash."
    print_info "Status: $(format_status PENDING)"
    print_info "Archive: ${GREEN}$NEW_ARCHIVE${NC}"

    # Flash the archived copies themselves so the preserved set and the
    # physically installed set are the exact same files.
    if ! flash_directory "$NEW_ARCHIVE"; then
        print_error "Flash Was Not Started Because Firmware Integrity Could Not Be Proven."
        pause_screen
        continue
    fi

    print_header "FLASH PASS COMPLETE"
    print_good "Flash Completed."
    print_warn "This Version Remains PENDING Until The Next Utility Run."
    print_info "Next Run Will Ask Whether Physical Testing Proved It GOOD Or BAD."
    pause_screen
    ;;

# =========================================================================================
# 2) RESTORE ARCHIVED FIRMWARE
# =========================================================================================

2)
    print_header "RESTORE ARCHIVED FIRMWARE"

    mapfile -t ARCHIVES < <(
        find "$ARCHIVE_DIR" \
            -mindepth 1 \
            -maxdepth 1 \
            -type d \
            | sort -r
    )

    if [[ ${#ARCHIVES[@]} -eq 0 ]]; then
        print_warn "No Archived Firmware Found."
        pause_screen
        continue
    fi

    print_info "Available Firmware Archives -- Newest First:"
    echo

    for i in "${!ARCHIVES[@]}"; do

        STATUS="UNKNOWN"

        if [[ -f "${ARCHIVES[$i]}/STATUS" ]]; then
            STATUS=$(cat "${ARCHIVES[$i]}/STATUS")
        fi

        printf "${CYAN}%3d)${NC} ${GREEN}%-22s${NC} [%s]\n" \
            "$((i + 1))" \
            "$(basename "${ARCHIVES[$i]}")" \
            "$(format_status "$STATUS")"
    done

    echo
    echo -ne "${YELLOW} = = > Select Archive To Restore: ${NC}${GREEN}"
    read -r NUMBER
    echo -ne "${NC}"

    if ! [[ "$NUMBER" =~ ^[0-9]+$ ]]; then
        print_error "Invalid Selection: $NUMBER"
        pause_screen
        continue
    fi

    INDEX=$((NUMBER - 1))

    if (( INDEX < 0 || INDEX >= ${#ARCHIVES[@]} )); then
        print_error "Archive Number Out Of Range: $NUMBER"
        pause_screen
        continue
    fi

    SELECTED="${ARCHIVES[$INDEX]}"

    REQUIRED_ARCHIVE_FILES=(
        "$SELECTED/snapack.ino.bootloader.bin"
        "$SELECTED/snapack.ino.partitions.bin"
        "$SELECTED/boot_app0.bin"
        "$SELECTED/snapack.ino.bin"
    )

    echo
    print_info "Verifying Selected Archive Before Flash..."

    for FILE in "${REQUIRED_ARCHIVE_FILES[@]}"; do
        if [[ ! -f "$FILE" ]]; then
            echo
            print_error "Archive Is Incomplete"
            echo -e "${CYAN}       Missing:${NC} ${YELLOW}$FILE${NC}"
            echo
            pause_screen
            continue 2
        fi
    done

    STATUS="UNKNOWN"
    if [[ -f "$SELECTED/STATUS" ]]; then
        STATUS=$(cat "$SELECTED/STATUS")
    fi

    if [[ ! -f "$SELECTED/SHA256SUMS" ]]; then
        echo
        print_error "SHA256SUMS Is Missing."
        print_warn "This Is A Legacy / Unverified Archive."
        print_error "RESTORE REFUSED -- A New Hash Will NOT Be Generated Retroactively."
        pause_screen
        continue
    fi

    if ! verify_firmware_archive "$SELECTED"; then
        print_error "Restore Refused Because Archive Integrity Could Not Be Proven."
        pause_screen
        continue
    fi

    echo
    print_info "Selected Archive: ${GREEN}$(basename "$SELECTED")${NC}"
    print_info "Recorded Status:  $(format_status "$STATUS")"
    echo

    if [[ "$STATUS" == "BAD" ]]; then
        echo -e "${REB} = = > WARNING: THIS ARCHIVE IS RECORDED AS BAD.${NC}"
        echo -e "${YE} = = > It Can Still Be Flashed Deliberately; Nothing Is Deleted Automatically.${NC}"
        echo
    fi

    print_header "READY TO RESTORE + FLASH"
    print_info "Proposed Operation:"
    echo -e "${CYAN}       Archive:${NC}      ${GREEN}$(basename "$SELECTED")${NC}"
    echo -e "${CYAN}       Status:${NC}       $(format_status "$STATUS")"
    echo -e "${CYAN}       Flash Device:${NC} ${GREEN}$PORT${NC}"
    echo -e "${CYAN}       Chip:${NC}         ${GREEN}ESP32-S3${NC}"
    echo
    echo -e "${YE} = = > The Selected Archived Firmware Will Be Flashed To The Controller.${NC}"
    echo -e "${YE} = = > No Flash Has Started Yet.${NC}"
    echo
    echo -ne "${YELLOW} = = > Press Enter To Restore + Flash, Or 0 To Return: ${NC}${GREEN}"
    read -r CONFIRM
    echo -ne "${NC}"

    if [[ "$CONFIRM" == "0" || "$CONFIRM" =~ ^[Qq]$ ]]; then
        print_warn "Restore Cancelled. No Flash Was Started."
        pause_screen
        continue
    fi

    if [[ -n "$CONFIRM" ]]; then
        print_warn "Restore Cancelled. No Flash Was Started."
        pause_screen
        continue
    fi

    if ! flash_directory "$SELECTED"; then
        print_error "Restore Was Not Started Because Firmware Integrity Could Not Be Proven."
        pause_screen
        continue
    fi

    # This archive is now the version physically installed on the controller.
    echo "$SELECTED" > "$STATE_FILE"

    print_header "RESTORE COMPLETE"
    print_good "Archived Firmware Restored Successfully."
    print_info "Installed Archive: ${GREEN}$(basename "$SELECTED")${NC}"
    print_info "Recorded Status:   $(format_status "$STATUS")"
    pause_screen
    ;;

# =========================================================================================
# 3) LIST FIRMWARE ARCHIVE
# =========================================================================================

3)
    print_header "SNAPACK FIRMWARE ARCHIVE"

    FOUND=0

    for DIR in "$ARCHIVE_DIR"/*/; do

        [[ -d "$DIR" ]] || continue
        FOUND=1

        STATUS="UNKNOWN"

        if [[ -f "$DIR/STATUS" ]]; then
            STATUS=$(cat "$DIR/STATUS")
        fi

        if [[ -f "$DIR/SHA256SUMS" ]]; then
            INTEGRITY="${GR}SHA-256${NC}"
        else
            INTEGRITY="${YE}LEGACY / UNVERIFIED${NC}"
        fi

        printf "${GREEN}%-22s${NC} [%s] [%b]\n" \
            "$(basename "$DIR")" \
            "$(format_status "$STATUS")" \
            "$INTEGRITY"
    done

    if [[ "$FOUND" -eq 0 ]]; then
        print_warn "No Archived Firmware Found."
    else
        echo
        print_info "Archive Root: ${GREEN}$ARCHIVE_DIR${NC}"
        print_info "GOOD=${GR}physically confirmed${NC}  PENDING=${YE}awaiting confirmation${NC}  BAD=${RE}retained known-bad${NC}"
    fi
    pause_screen
    ;;

# =========================================================================================
# 4) CAPTURE FULL DEVICE IMAGE
# =========================================================================================

4)
    if capture_full_flash_image; then
        pause_screen
    else
        pause_screen
    fi
    ;;

# =========================================================================================
# 5) EXIT
# =========================================================================================

5)
    echo
    print_info "SNAPACK Firmware Utility Exiting."
    exit 0
    ;;

# =========================================================================================
# INVALID MENU SELECTION
# =========================================================================================

*)
    echo
    print_error "Invalid Menu Selection: $CHOICE"
    pause_screen
    ;;

esac

done
