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

BOOT_APP0="/home/valued/.arduino15/packages/esp32/hardware/esp32/2.0.14/tools/partitions/boot_app0.bin"

ESPTOOL="$HOME/.local/bin/esptool"
PORT="/dev/ttyACM0"

STATE_FILE="$ARCHIVE_DIR/.last_flash"

mkdir -p "$ARCHIVE_DIR"

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
    echo
    echo -ne "${CYAN} = = >${NC} ${YELLOW}Press Enter To Continue...${NC}"
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
echo -e "${YELLOW}     4) Exit${NC}"
echo
echo -e "${CYAN} = = > Build Source:${NC}   ${GREEN}$BUILD_DIR${NC}"
echo -e "${CYAN} = = > Archive Root:${NC}   ${GREEN}$ARCHIVE_DIR${NC}"
echo -e "${CYAN} = = > Flash Device:${NC}   ${GREEN}$PORT${NC}"
echo

echo -ne "${YELLOW} = = > Select Mission [1-4]: ${NC}${GREEN}"
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
            exit 1
        fi
        echo -e "${GR}       FOUND:${NC} ${GREEN}$FILE${NC}"
    done

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
    flash_directory "$NEW_ARCHIVE"

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
        exit 1
    fi

    INDEX=$((NUMBER - 1))

    if (( INDEX < 0 || INDEX >= ${#ARCHIVES[@]} )); then
        print_error "Archive Number Out Of Range: $NUMBER"
        exit 1
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
            exit 1
        fi
    done

    STATUS="UNKNOWN"
    if [[ -f "$SELECTED/STATUS" ]]; then
        STATUS=$(cat "$SELECTED/STATUS")
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

    echo -ne "${YELLOW} = = > Flash This Archived Version? [y/N]: ${NC}${GREEN}"
    read -r CONFIRM
    echo -ne "${NC}"

    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        print_warn "Restore Cancelled. No Flash Was Started."
        pause_screen
        continue
    fi

    flash_directory "$SELECTED"

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

        printf "${GREEN}%-22s${NC} [%s]\n" \
            "$(basename "$DIR")" \
            "$(format_status "$STATUS")"
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
# 4) EXIT
# =========================================================================================

4)
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
