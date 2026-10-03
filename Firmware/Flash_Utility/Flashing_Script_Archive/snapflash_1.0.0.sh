#!/bin/bash

# VERSION NOTE:
# The SNAPACK recovery storage directory was renamed from archive to recovery.
# Older utility versions expect the archive directory while Version 1.0.0 and later expect recovery.
# Firmware behavior and flash addresses were not changed.

# =========================================================================================
# SNAPACK FIRMWARE ARCHIVE / FLASH / RESTORE UTILITY
# VERSION: 1.0.0
# =========================================================================================
# PURPOSE:
# - Archive every newly exported SNAPACK firmware build BEFORE it is flashed.
# - Keep the exact four-file ESP32-S3 flash set together as one restorable unit.
# - Remember which archived version was flashed most recently.
# - Ask before the NEXT write operation whether the previously flashed firmware proved GOOD or BAD.
# - Restore any retained four-BIN firmware archive without rebuilding old source code.
# - Capture, verify, and restore complete 16 MiB device images as a second recovery path.
#
# WORKFLOW PHILOSOPHY:
# - The archive copy is the authority for the flash operation.
# - A newly written four-BIN version becomes PENDING only AFTER esptool reports success.
# - BAD means "known bad in physical testing"; it is retained, not silently deleted.
# - Restores flash the archived binaries/images exactly as they were preserved.
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
GRB=$'\033[5;32m'

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
ARCHIVE_DIR="/home/valued/Arduino/snapack/recovery/bin_backup"
IMAGE_ARCHIVE_DIR="/home/valued/Arduino/snapack/recovery/device_images"

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

# Return the first human-readable archive note line, or an empty string when no note exists.
# NOTES.txt is deliberately NOT part of SHA256SUMS: it is descriptive metadata that may be
# added or edited by a human without changing the cryptographic identity of the firmware BINs.
get_archive_note() {
    local dir="$1"

    if [[ -s "$dir/NOTES.txt" ]]; then
        head -n 1 "$dir/NOTES.txt"
    fi
}

# =========================================================================================
# MARKER: STARTUP HARDWARE TARGET SPLASH
# =========================================================================================
# PURPOSE:
# - Make the intended hardware target visible every time the utility starts.
# - This is deliberately informational rather than another required keystroke; the main menu
#   follows immediately below it so normal use does not accumulate unnecessary prompts.
#
# IMPORTANT FOR FUTURE HUMANS:
# - These archives contain a board-specific ESP32-S3 flash layout. A valid hash proves that
#   an archive has not changed; it does NOT prove that the archive belongs on arbitrary
#   hardware. Integrity and hardware compatibility are separate requirements.
# =========================================================================================

print_target_splash() {
    print_header "SNAPACK HARDWARE TARGET WARNING"
    echo -e "${YE} = = > These Firmware And Recovery Images And Even This Script-Utility Are For The ${NC}"
    echo -e "${GR} = = > Elecrow DHE03921D 2.1-Inch Round 480x480 ESP32-S3 Display Controller.${NC}"
    echo
    echo -e "${REB} = = > DO NOT FLASH THESE ARCHIVES TO A DIFFERENT DISPLAY / CONTROLLER MODEL.${NC}"
    echo
	echo -e "${YE} = = > EVEN ANOTHER ELECROW DEVICE OF THE SAME MODEL SHOULD NOT BE FLASHED WITHOUT FIRST VERIFYING ${NC}"
    echo -e "${YE} = = > HARDWARE COMPATIBILITY ACROSS MODEL, YEARS, PRODUCTION-LOTS, PARTITION-LOCATIONS, ETC..${NC}"
    echo -e "${YE} = = > WE ARE JUST SAYING -DO YOUR DUE DILIGENCE FIRST OR PAY THE PRICE- ...${NC}"
    echo

    print_info "Established Flash Layout: ${GREEN}ESP32-S3 / DIO / 80 MHz / 16 MB${NC}"
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

    # sha256sum -c verifies only the entries that are PRESENT in the manifest. Therefore an
    # accidentally truncated manifest could otherwise omit one firmware file and still return
    # success. Require all four authoritative filenames to appear exactly once before checking.
    if [[ $(wc -l < "$dir/SHA256SUMS") -ne ${#FIRMWARE_FILES[@]} ]]; then
        print_error "SHA256SUMS Does Not Contain Exactly Four Firmware Entries."
        print_error "FLASH REFUSED."
        return 1
    fi

    for file in "${FIRMWARE_FILES[@]}"; do
        if [[ $(awk -v name="$file" '$2 == name {count++} END {print count+0}' "$dir/SHA256SUMS") -ne 1 ]]; then
            print_error "SHA256SUMS Does Not Contain Exactly One Entry For: $file"
            print_error "FLASH REFUSED."
            return 1
        fi
    done

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
    echo -e "${YEB} = = > FLASH WRITE STARTING -- DO NOT INTERRUPT THE USB CONNECTION.${NC}"
    echo

    # DO NOT rely on `set -e` here. This function is intentionally called from `if ! ...`;
    # Bash suppresses errexit semantics in that context. Without this explicit test, a failed
    # esptool command could fall through to the success message and make the function return 0.
    if ! "$ESPTOOL" \
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
    then
        echo
        print_error "esptool Flash Write Failed."
        print_warn "No Success State Will Be Recorded For This Attempt."
        return 1
    fi

    echo
    print_good "esptool Returned Successfully."
    return 0
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

    # Like firmware archives, full-image directories are immutable recovery units.
    if ! mkdir "$image_dir"; then
        print_error "Could Not Create A Unique Device Image Archive Directory."
        return 1
    fi

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

    if ! actual_size=$(stat -c '%s' "$image_path"); then
        print_error "Could Not Determine Captured Device Image Size."
        print_warn "Unverified Image Folder Will Be Removed."
        rm -rf -- "$image_dir"
        return 1
    fi

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
    if ! (
        cd "$image_dir"
        sha256sum snapack_full_flash_16MB.bin > SHA256SUMS
    ); then
        print_error "Could Not Generate Device Image SHA256SUMS."
        print_warn "Unverified Image Folder Will Be Removed."
        rm -rf -- "$image_dir"
        return 1
    fi

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
# MARKER: FULL DEVICE IMAGE INTEGRITY / RESTORE ENGINE
# =========================================================================================
# PURPOSE:
# - Treat a complete 16 MiB readback as a second, independent recovery archive type.
# - A hash created immediately after device readback protects that captured image from the
#   time of capture forward.
#
# IMPORTANT DISTINCTION:
# - Hashing a newly captured physical-device image is legitimate because we are establishing
#   the integrity identity of a NEW recovery artifact at capture time.
# - This does NOT retroactively authenticate any old, loose, previously-unhashed BIN files
#   that may once have been used to program the device.
# =========================================================================================

verify_full_flash_image() {
    local dir="$1"
    local image_path="$dir/snapack_full_flash_16MB.bin"
    local actual_size

    print_header "FULL DEVICE IMAGE INTEGRITY CHECK"
    print_info "Image Archive: ${GREEN}$dir${NC}"

    if [[ ! -f "$image_path" ]]; then
        print_error "Full Device Image Is Missing."
        print_error "IMAGE RESTORE REFUSED."
        return 1
    fi

    if [[ ! -f "$dir/SHA256SUMS" ]]; then
        print_error "SHA256SUMS Is Missing."
        print_warn "A New Hash Will NOT Be Invented At Restore Time."
        print_error "IMAGE RESTORE REFUSED."
        return 1
    fi

    # A complete-device image archive has exactly one protected payload. Refuse a truncated,
    # expanded, or otherwise structurally unexpected manifest before trusting sha256sum -c.
    if [[ $(wc -l < "$dir/SHA256SUMS") -ne 1 ]] || \
       [[ $(awk '$2 == "snapack_full_flash_16MB.bin" {count++} END {print count+0}' "$dir/SHA256SUMS") -ne 1 ]]; then
        print_error "SHA256SUMS Does Not Contain Exactly One Full-Image Entry."
        print_error "IMAGE RESTORE REFUSED."
        return 1
    fi

    if ! actual_size=$(stat -c '%s' "$image_path"); then
        print_error "Could Not Determine Device Image Size."
        return 1
    fi

    if [[ "$actual_size" -ne "$FULL_FLASH_SIZE_BYTES" ]]; then
        print_error "Device Image Size Check Failed."
        echo -e "${CYAN}       Expected:${NC} ${GREEN}$FULL_FLASH_SIZE_BYTES bytes${NC}"
        echo -e "${CYAN}       Received:${NC} ${YELLOW}$actual_size bytes${NC}"
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
        print_error "Device Image SHA-256 Verification Failed."
        print_error "IMAGE RESTORE REFUSED."
        return 1
    fi

    echo
    print_good "Full Device Image Size And SHA-256 Verification Passed."
    return 0
}

flash_full_image() {
    local dir="$1"
    local image_path="$dir/snapack_full_flash_16MB.bin"

    # Just like the four-BIN engine, the complete-image write has an absolute integrity gate.
    if ! verify_full_flash_image "$dir"; then
        return 1
    fi

    print_header "FULL DEVICE IMAGE RESTORE ENGINE"
    print_info "Image Archive: ${GREEN}$dir${NC}"
    print_info "Target Port:   ${GREEN}$PORT${NC}"
    print_info "Write Range:   ${GREEN}0x00000000 - 0x00FFFFFF${NC}"
    print_info "Image Size:    ${GREEN}16 MiB${NC}"
    echo
    echo -e "${REB} = = > COMPLETE FLASH-DEVICE RESTORE STARTING.${NC}"
    echo -e "${YEB} = = > DO NOT INTERRUPT THE USB CONNECTION.${NC}"
    echo

    # Explicitly test esptool. See flash_directory() for the Bash/set -e reason.
    if ! "$ESPTOOL" \
        --no-stub \
        --chip esp32s3 \
        --port "$PORT" \
        write-flash \
        --flash-mode dio \
        --flash-freq 80m \
        --flash-size 16MB \
        0x0000 "$image_path"
    then
        echo
        print_error "Full Device Image Write Failed."
        print_warn "No Success State Will Be Recorded For This Attempt."
        return 1
    fi

    echo
    print_good "Full 16 MiB Device Image Write Returned Successfully."
    return 0
}

# =========================================================================================
# MARKER: PREVIOUS FLASH BOOKKEEPING
# =========================================================================================
# PURPOSE:
# - Four-BIN firmware written successfully by this utility is marked PENDING.
# - The physical GOOD/BAD question is intentionally NOT asked merely because the utility
#   started. Listing archives, capturing a device image, or exiting should not force an
#   unrelated firmware judgment.
# - Instead, this function is called immediately before any operation that is preparing to
#   WRITE firmware/image data to the controller.
#
# STATE SEMANTICS:
# - .last_flash records what this utility most recently succeeded in writing to the device.
# - STATUS belongs to four-BIN firmware archives and records physical/functional judgment.
# - A full-device image archive does not acquire a fabricated four-BIN GOOD/BAD STATUS simply
#   because it was restored; the state pointer may still identify it as the last write.
# =========================================================================================

evaluate_previous_pending_flash() {
    local last_archive current_status answer

    [[ -f "$STATE_FILE" ]] || return 0

    if ! last_archive=$(cat "$STATE_FILE"); then
        print_warn "Could Not Read Previous Flash State File; Continuing Without Status Update."
        return 0
    fi

    [[ -d "$last_archive" ]] || return 0
    [[ -f "$last_archive/STATUS" ]] || return 0

    current_status=$(cat "$last_archive/STATUS")
    [[ "$current_status" == "PENDING" ]] || return 0

    print_header "PREVIOUS FLASH STATUS CHECK"
    print_info "Previous Flashed Version: ${GREEN}$(basename "$last_archive")${NC}"
    print_info "Current Archive Status:   $(format_status "$current_status")"
    echo
    echo -e "${YE} = = > This asks about PHYSICAL / FUNCTIONAL success, not whether esptool ran.${NC}"
    echo -e "${YE} = = > The question appears now because another device WRITE operation was selected.${NC}"
    echo

    while true; do
        echo -ne "${YELLOW} = = > Was the previous flash successful? [Y/n]: ${NC}${GREEN}"
        read -r answer
        echo -ne "${NC}"
        answer=${answer:-Y}

        case "$answer" in
            [Yy])
                if echo "GOOD" > "$last_archive/STATUS"; then
                    print_good "Previous Version Marked GOOD: $(basename "$last_archive")"
                    break
                else
                    print_error "Could Not Update Previous Archive STATUS To GOOD."
                    return 1
                fi
                ;;
            [Nn])
                if echo "BAD" > "$last_archive/STATUS"; then
                    print_warn "Previous Version Marked BAD And Retained: $(basename "$last_archive")"
                    break
                else
                    print_error "Could Not Update Previous Archive STATUS To BAD."
                    return 1
                fi
                ;;
            *)
                print_warn "Please Enter Y Or N. Pressing Enter Means Y."
                ;;
        esac
    done

    return 0
}

# =========================================================================================
# MARKER: MAIN MENU
# =========================================================================================

print_target_splash

while true; do

print_header "SNAPACK FIRMWARE UTILITY"

echo -e "${YELLOW}     1) Archive And Flash Newest Arduino Build${NC}"
echo -e "${YELLOW}     2) Restore Archived Four-BIN Firmware${NC}"
echo -e "${YELLOW}     3) Restore Full 16 MB Device Image${NC}"
echo -e "${YELLOW}     4) List Recovery Archives${NC}"
echo -e "${YELLOW}     5) Capture Full 16 MB Device Image${NC}"
echo -e "${YELLOW}     6) Exit${NC}"
echo
echo -e "${CYAN} = = > Build Source:${NC}   ${GREEN}$BUILD_DIR${NC}"
echo -e "${CYAN} = = > Archive Root:${NC}   ${GREEN}$ARCHIVE_DIR${NC}"
echo -e "${CYAN} = = > Image Root:${NC}     ${GREEN}$IMAGE_ARCHIVE_DIR${NC}"
echo -e "${CYAN} = = > Flash Device:${NC}   ${GREEN}$PORT${NC}"
echo

echo -ne "${YELLOW} = = > Select Mission [1-6]: ${NC}${GREEN}"
read -r CHOICE
echo -ne "${NC}"

case "$CHOICE" in

# =========================================================================================
# 1) ARCHIVE + FLASH NEW BUILD
# =========================================================================================

1)
    if ! evaluate_previous_pending_flash; then
        pause_screen
        continue
    fi

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

    # Archive directories are immutable recovery units. Never merge a new build into an
    # existing timestamp directory; a collision is safer to stop than to overwrite.
    if ! mkdir "$NEW_ARCHIVE"; then
        print_error "Could Not Create A Unique Firmware Archive Directory."
        print_warn "No Existing Archive Was Modified And No Flash Was Attempted."
        pause_screen
        continue
    fi

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

    print_good "Archive Created And Cryptographically Verified Before Flash."
    print_info "Archive: ${GREEN}$NEW_ARCHIVE${NC}"
    print_info "Status: ${GRAY}NOT YET WRITTEN TO DEVICE${NC}"

    # -------------------------------------------------------------------------
    # OPTIONAL HUMAN DESCRIPTION
    # -------------------------------------------------------------------------
    # Timestamps are reliable machine identifiers but poor human memory aids. Allow the
    # operator to attach one short descriptive line explaining what made this build notable.
    # The note is intentionally stored in NOTES.txt and is NOT included in SHA256SUMS.
    # Editing descriptive metadata later must never alter firmware identity or GOOD/BAD/PENDING.
    echo
    echo -ne "${YELLOW} = = > Add A Short Human-Readable Description To This Archive? [y/N]: ${NC}${GREEN}"
    read -r ADD_NOTE
    echo -ne "${NC}"
    ADD_NOTE=${ADD_NOTE:-N}

    if [[ "$ADD_NOTE" =~ ^[Yy]$ ]]; then
        echo -ne "${YELLOW} = = > Description: ${NC}${GREEN}"
        read -r ARCHIVE_NOTE
        echo -ne "${NC}"

        if [[ -n "$ARCHIVE_NOTE" ]]; then
            if printf '%s\n' "$ARCHIVE_NOTE" > "$NEW_ARCHIVE/NOTES.txt"; then
                print_good "Archive Description Saved: $ARCHIVE_NOTE"
            else
                print_error "Could Not Write NOTES.txt."
                print_warn "Firmware Archive Remains Valid; Description Was Not Saved."
            fi
        else
            print_warn "No Description Entered; Archive Will Remain Timestamp-Only."
        fi
    else
        print_info "No Description Added."
    fi

    # Flash the archived copies themselves so the preserved set and the
    # physically installed set are the exact same files.
    if ! flash_directory "$NEW_ARCHIVE"; then
        print_error "Firmware Write Did Not Complete Successfully."
        print_warn "The Verified Archive Has Been Retained, But It Was NOT Marked PENDING."
        print_warn ".last_flash Was NOT Changed Because Physical Installation Was Not Proven."
        pause_screen
        continue
    fi

    # Only a successful esptool write is allowed to create physical-installation state.
    # PENDING therefore means exactly: written successfully, awaiting human evaluation.
    if ! echo "PENDING" > "$NEW_ARCHIVE/STATUS"; then
        print_error "Flash Succeeded But STATUS Could Not Be Written."
        print_warn "Manual Archive Inspection Is Required Before The Next Write Operation."
        pause_screen
        continue
    fi

    if ! echo "$NEW_ARCHIVE" > "$STATE_FILE"; then
        print_error "Flash Succeeded But .last_flash Could Not Be Updated."
        print_warn "The Controller Was Written Successfully; Bookkeeping Requires Manual Repair."
        pause_screen
        continue
    fi

    print_header "FLASH PASS COMPLETE"
    print_good "Flash Completed And Installation State Recorded."
    print_info "Status: $(format_status PENDING)"
    print_warn "This Version Awaits Physical GOOD / BAD Evaluation."
    print_info "That Question Will Appear Before The Next Device WRITE Operation."
    pause_screen
    ;;

# =========================================================================================
# 2) RESTORE ARCHIVED FIRMWARE
# =========================================================================================

2)
    if ! evaluate_previous_pending_flash; then
        pause_screen
        continue
    fi

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

        NOTE=$(get_archive_note "${ARCHIVES[$i]}")

        printf "${CYAN}%3d)${NC} ${GREEN}%-22s${NC} [%s]\n" \
            "$((i + 1))" \
            "$(basename "${ARCHIVES[$i]}")" \
            "$(format_status "$STATUS")"

        if [[ -n "$NOTE" ]]; then
            echo -e "${CYAN}       Note:${NC} ${WHITE}$NOTE${NC}"
        fi
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
    SELECTED_NOTE=$(get_archive_note "$SELECTED")
    if [[ -n "$SELECTED_NOTE" ]]; then
        print_info "Description:      ${WHITE}$SELECTED_NOTE${NC}"
    fi
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
        print_error "Archived Firmware Restore Did Not Complete Successfully."
        print_warn ".last_flash Was NOT Changed."
        pause_screen
        continue
    fi

    # This archive is now the version physically installed on the controller. Its historical
    # GOOD/BAD status remains unchanged; installation state and evaluation history are separate.
    if ! echo "$SELECTED" > "$STATE_FILE"; then
        print_error "Restore Succeeded But .last_flash Could Not Be Updated."
        print_warn "The Controller Was Written Successfully; Bookkeeping Requires Manual Repair."
        pause_screen
        continue
    fi

    print_header "RESTORE COMPLETE"
    print_good "Archived Firmware Restored Successfully."
    print_info "Installed Archive: ${GREEN}$(basename "$SELECTED")${NC}"
    print_info "Recorded Status:   $(format_status "$STATUS")"
    pause_screen
    ;;

# =========================================================================================
# 3) RESTORE FULL DEVICE IMAGE
# =========================================================================================

3)
    if ! evaluate_previous_pending_flash; then
        pause_screen
        continue
    fi

    print_header "RESTORE FULL 16 MB DEVICE IMAGE"

    mapfile -t IMAGES < <(
        find "$IMAGE_ARCHIVE_DIR" \
            -mindepth 1 \
            -maxdepth 1 \
            -type d \
            | sort -r
    )

    if [[ ${#IMAGES[@]} -eq 0 ]]; then
        print_warn "No Full Device Images Found."
        pause_screen
        continue
    fi

    print_info "Available Full Device Images -- Newest First:"
    echo

    for i in "${!IMAGES[@]}"; do
        if [[ -f "${IMAGES[$i]}/SHA256SUMS" ]]; then
            INTEGRITY="${GR}SHA-256${NC}"
        else
            INTEGRITY="${YE}UNVERIFIED${NC}"
        fi

        printf "${CYAN}%3d)${NC} ${GREEN}%-22s${NC} [%b]\n" \
            "$((i + 1))" \
            "$(basename "${IMAGES[$i]}")" \
            "$INTEGRITY"
    done

    echo
    echo -ne "${YELLOW} = = > Select Full Device Image To Restore: ${NC}${GREEN}"
    read -r NUMBER
    echo -ne "${NC}"

    if ! [[ "$NUMBER" =~ ^[0-9]+$ ]]; then
        print_error "Invalid Selection: $NUMBER"
        pause_screen
        continue
    fi

    INDEX=$((NUMBER - 1))
    if (( INDEX < 0 || INDEX >= ${#IMAGES[@]} )); then
        print_error "Image Number Out Of Range: $NUMBER"
        pause_screen
        continue
    fi

    SELECTED_IMAGE="${IMAGES[$INDEX]}"

    if ! verify_full_flash_image "$SELECTED_IMAGE"; then
        print_error "Full Device Image Restore Refused Because Integrity Could Not Be Proven."
        pause_screen
        continue
    fi

    print_header "READY TO RESTORE COMPLETE DEVICE IMAGE"
    print_info "Selected Image: ${GREEN}$(basename "$SELECTED_IMAGE")${NC}"
    print_info "Flash Device:   ${GREEN}$PORT${NC}"
    echo
    echo -e "${REB} = = > THIS WRITES THE COMPLETE 16 MiB FLASH DEVICE FROM ADDRESS 0x00000000.${NC}"
    echo -e "${YE} = = > It is a low-level recovery restore, not a normal four-BIN Arduino update.${NC}"
    echo
    echo -ne "${YELLOW} = = > Press Enter To Restore Full Image, Or 0 To Return: ${NC}${GREEN}"
    read -r CONFIRM
    echo -ne "${NC}"

    if [[ "$CONFIRM" == "0" || "$CONFIRM" =~ ^[Qq]$ || -n "$CONFIRM" ]]; then
        print_warn "Full Device Image Restore Cancelled. No Flash Was Started."
        pause_screen
        continue
    fi

    if ! flash_full_image "$SELECTED_IMAGE"; then
        print_error "Full Device Image Restore Did Not Complete Successfully."
        print_warn ".last_flash Was NOT Changed."
        pause_screen
        continue
    fi

    # A full-image archive is a different recovery artifact type, so it does not receive a
    # fabricated four-BIN STATUS. .last_flash may still record what was physically written.
    if ! echo "$SELECTED_IMAGE" > "$STATE_FILE"; then
        print_error "Image Restore Succeeded But .last_flash Could Not Be Updated."
        print_warn "The Controller Was Written Successfully; Bookkeeping Requires Manual Repair."
        pause_screen
        continue
    fi

    print_header "FULL DEVICE IMAGE RESTORE COMPLETE"
    print_good "Complete 16 MiB Device Image Restored Successfully."
    print_info "Installed Image: ${GREEN}$(basename "$SELECTED_IMAGE")${NC}"
    pause_screen
    ;;

# =========================================================================================
# 4) LIST RECOVERY ARCHIVES
# =========================================================================================

4)
    print_header "SNAPACK RECOVERY ARCHIVES"

    print_info "FOUR-BIN FIRMWARE ARCHIVES:"
    echo
    FOUND=0

    for DIR in "$ARCHIVE_DIR"/*/; do
        [[ -d "$DIR" ]] || continue
        FOUND=1

        STATUS="UNKNOWN"
        if [[ -f "$DIR/STATUS" ]]; then
            STATUS=$(cat "$DIR/STATUS")
        elif [[ -f "$DIR/SHA256SUMS" ]]; then
            STATUS="NOT-FLASHED/UNKNOWN"
        fi

        if [[ -f "$DIR/SHA256SUMS" ]]; then
            INTEGRITY="${GR}SHA-256${NC}"
        else
            INTEGRITY="${YE}LEGACY / UNVERIFIED${NC}"
        fi

        NOTE=$(get_archive_note "$DIR")

        printf "${GREEN}%-22s${NC} [%s] [%b]\n" \
            "$(basename "$DIR")" \
            "$(format_status "$STATUS")" \
            "$INTEGRITY"

        if [[ -n "$NOTE" ]]; then
            echo -e "${CYAN}    Note:${NC} ${WHITE}$NOTE${NC}"
        fi
    done

    if [[ "$FOUND" -eq 0 ]]; then
        print_warn "No Four-BIN Firmware Archives Found."
    fi

    echo
    print_info "FULL 16 MiB DEVICE IMAGES:"
    echo
    IMAGE_FOUND=0

    for DIR in "$IMAGE_ARCHIVE_DIR"/*/; do
        [[ -d "$DIR" ]] || continue
        IMAGE_FOUND=1

        if [[ -f "$DIR/SHA256SUMS" ]]; then
            INTEGRITY="${GR}SHA-256${NC}"
        else
            INTEGRITY="${YE}UNVERIFIED${NC}"
        fi

        printf "${GREEN}%-22s${NC} [%b]\n" \
            "$(basename "$DIR")" \
            "$INTEGRITY"
    done

    if [[ "$IMAGE_FOUND" -eq 0 ]]; then
        print_warn "No Full Device Images Found."
    fi

    echo
    print_info "Firmware Root: ${GREEN}$ARCHIVE_DIR${NC}"
    print_info "Image Root:    ${GREEN}$IMAGE_ARCHIVE_DIR${NC}"
    print_info "GOOD=${GR}physically confirmed${NC}  PENDING=${YE}awaiting confirmation${NC}  BAD=${RE}retained known-bad${NC}"
    pause_screen
    ;;

# =========================================================================================
# 5) CAPTURE FULL DEVICE IMAGE
# =========================================================================================

5)
    if capture_full_flash_image; then
        pause_screen
    else
        pause_screen
    fi
    ;;

# =========================================================================================
# 6) EXIT
# =========================================================================================

6)
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
