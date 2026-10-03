#!/bin/bash

# VERSION NOTE:
# The SNAPACK recovery storage directory was renamed from archive to recovery.
# Older utility versions expect the archive directory while Version 1.0.0 and later expect recovery.
# Firmware behavior and flash addresses were not changed.

# =========================================================================================
# SNAPACK FIRMWARE ARCHIVE / FLASH / RESTORE UTILITY
# VERSION: 1.2.1
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
# - Option 1 compiles with the frozen AppImage CLI into isolated staging.
# - Option 6 retains the established Arduino IDE Export Compiled Binary fallback.
# - Both options flash only verified archived copies with esptool.
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
TRUSTED_DEVICES_FILE="/home/valued/Arduino/snapack/recovery/trusted_devices.txt"

BOOT_APP0="/home/valued/.arduino15/packages/esp32/hardware/esp32/2.0.14/tools/partitions/boot_app0.bin"

ESPTOOL="$HOME/.local/bin/esptool"
PORT="/dev/ttyACM0"

# Frozen, verified IDE-equivalent compilation configuration. Do not auto-install or update anything.
SKETCH_DIR="/home/valued/Arduino/snapack"
CLI="/tmp/.mount_arduinjI3U8J/resources/app/lib/backend/resources/arduino-cli"
FQBN='esp32:esp32:esp32s3:UploadSpeed=460800,USBMode=hwcdc,CDCOnBoot=cdc,MSCOnBoot=default,DFUOnBoot=default,UploadMode=default,CPUFreq=240,FlashMode=qio,FlashSize=16M,PartitionScheme=huge_app,DebugLevel=none,PSRAM=opi,LoopCore=1,EventsCore=1,EraseFlash=none,JTAGAdapter=default'
IDE_BUILD_DIR="$BUILD_DIR"
BUILD_ORIGIN="Arduino IDE export"
STAGED_BUILD=""
STAGED_SOURCE=""
STAGED_WIFI_HASH=""
STATE_FILE="$ARCHIVE_DIR/.last_flash"

FULL_FLASH_SIZE_HEX="0x1000000"
FULL_FLASH_SIZE_BYTES=16777216

mkdir -p "$ARCHIVE_DIR"
mkdir -p "$IMAGE_ARCHIVE_DIR"
mkdir -p "$(dirname "$TRUSTED_DEVICES_FILE")"

# =========================================================================================
# MARKER: DISPLAY HELPERS
# =========================================================================================
# SCREEN LIFECYCLE RULE:
# - Each major SnapFlash view owns a clean terminal screen.
# - Information that must remain visible ends with an Enter acknowledgment.
# - After acknowledgment, the next major view clears stale output before drawing itself.
# - This prevents delete/restore/verification remnants from accumulating above later menus.
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

clear_screen() {
    # Keep screen transitions deliberate. `clear` is preferred, but fall back to ANSI home/clear
    # if the terminal database is unavailable for some reason.
    if ! clear 2>/dev/null; then
        printf '\033[2J\033[H'
    fi
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
# - This is deliberately a standalone splash page with an Enter gate. The warning remains
#   visible by itself until acknowledged, then the terminal is cleared before the main menu.
#
# IMPORTANT FOR FUTURE HUMANS:
# - These archives contain a board-specific ESP32-S3 flash layout. A valid hash proves that
#   an archive has not changed; it does NOT prove that the archive belongs on arbitrary
#   hardware. Integrity and hardware compatibility are separate requirements.
# =========================================================================================

print_target_splash() {
    clear_screen
    print_header "SNAPACK HARDWARE TARGET WARNING"
    echo -e "${YE} = = > These Firmware And Recovery Images And Even This Script-Utility Are For The ${NC}"
    echo
    echo -e "${GR} = = > Elecrow DHE03921D 2.1-Inch Round 480x480 ESP32-S3 Display Controller.${NC}"
    echo
    echo -e "${REB} = = > DO NOT FLASH THESE ARCHIVES TO A DIFFERENT DISPLAY / CONTROLLER MODEL.${NC}"
    echo
    echo -e "${YE} = = > EVEN ANOTHER ELECROW DEVICE OF THE SAME MODEL SHOULD NOT BE FLASHED WITHOUT FIRST VERIFYING ${NC}"
    echo
    echo -e "${YE} = = > HARDWARE COMPATIBILITY ACROSS MODEL, YEARS, PRODUCTION-LOTS, PARTITION-LOCATIONS, ETC..${NC}"
    echo
    echo -e "${YE} = = > WE ARE JUST SAYING -DO YOUR DUE DILIGENCE FIRST OR PAY THE PRICE- ...${NC}"
    echo
    print_info "Established Flash Layout: ${GREEN}ESP32-S3 / DIO / 80 MHz / 16 MB${NC}"
    pause_screen "Press Enter To Continue..."
    clear_screen
}

# =========================================================================================
# MARKER: PHYSICAL CONTROLLER READINESS / TRUST GATE
# =========================================================================================
# PURPOSE:
# - Do not let a device-dependent mission proceed when no ESP32-S3 is actually available.
# - Refuse early if another process already owns the configured serial port. A terminal monitor
#   running inside a shell `while true` loop is one important example of this failure mode.
# - Read the controller base MAC with esptool before archive selection or other mission work.
# - Compare that MAC with a deliberately maintained trusted-controller registry.
# - Unknown controllers are NEVER enrolled silently.
#
# TRUST MODEL:
# - A known MAC means this individual controller was previously approved for SNAPACK work.
# - An unknown MAC may be approved and saved, used once without saving, or rejected.
# - MAC trust does NOT prove board-model compatibility; the startup hardware warning remains
#   authoritative for that separate question.
#
# SERIAL-PORT SAFETY RULE:
# - The readiness order is: device node exists -> serial port is free -> ESP32-S3 responds ->
#   MAC is read -> trusted-controller status is checked.
# - If another process owns the port, show its PID/command when practical and REFUSE the mission.
# - SnapFlash never kills the occupying process automatically; the operator decides what to close.
#
# FINAL SAFETY RULE:
# - A second quiet communication/MAC check occurs before every device operation. This catches a
#   controller that was disconnected, powered down, or replaced after the early mission gate.
# - Port occupancy is checked again immediately before the actual read/write command so a serial
#   monitor started after the initial gate does not turn into an unexplained esptool failure.
# =========================================================================================

CONTROLLER_MAC=""
CONTROLLER_TRUST="UNKNOWN"

# Return success when the configured serial port is currently held by another process.
# Return 1 when the port appears free. Return 2 when no supported occupancy detector exists.
serial_port_busy() {
    if command -v fuser >/dev/null 2>&1; then
        if fuser -s "$PORT" 2>/dev/null; then
            return 0
        fi
        return 1
    fi

    if command -v lsof >/dev/null 2>&1; then
        if lsof -t -- "$PORT" 2>/dev/null | grep -q .; then
            return 0
        fi
        return 1
    fi

    return 2
}

# Best-effort diagnostics only. Failure to identify the holder does not weaken the busy-port gate.
print_serial_port_holders() {
    local pids=() pid details

    if command -v fuser >/dev/null 2>&1; then
        mapfile -t pids < <(fuser "$PORT" 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -u || true)
    elif command -v lsof >/dev/null 2>&1; then
        mapfile -t pids < <(lsof -t -- "$PORT" 2>/dev/null | grep -E '^[0-9]+$' | sort -u || true)
    fi

    if [[ ${#pids[@]} -eq 0 ]]; then
        print_warn "The Port Is Busy, But The Owning PID Could Not Be Identified."
        return 0
    fi

    echo
    print_warn "Process(es) Currently Holding $PORT:"
    for pid in "${pids[@]}"; do
        if details=$(ps -p "$pid" -o pid=,user=,comm=,args= 2>/dev/null); then
            echo -e "${CYAN}       PID / Command:${NC} ${WHITE}$details${NC}"
        else
            echo -e "${CYAN}       PID:${NC} ${WHITE}$pid${NC}"
        fi
    done
}

# Shared visible/quiet gate. Quiet mode still prints an actionable error when it refuses an
# operation; it merely omits normal PASS chatter. This function NEVER kills a process.
ensure_serial_port_free() {
    local mode="${1:-visible}" rc

    if serial_port_busy; then
        if [[ "$mode" == "visible" ]]; then
            echo -e "${RE} = = > Serial port available ........... FAIL${NC}"
        fi
        print_error "Serial Port Is Already In Use: $PORT"
        print_serial_port_holders
        print_warn "Close The Serial Monitor / Terminal Process And Try Again."
        print_warn "SnapFlash Will Not Kill The Process Automatically."
        return 1
    else
        rc=$?
    fi

    if (( rc == 2 )); then
        if [[ "$mode" == "visible" ]]; then
            echo -e "${RE} = = > Serial port occupancy check ..... UNAVAILABLE${NC}"
        fi
        print_error "Cannot Verify Whether $PORT Is Already In Use."
        print_warn "Install/restore 'fuser' (psmisc) or provide 'lsof' before using device operations."
        return 1
    fi

    if [[ "$mode" == "visible" ]]; then
        echo -e "${GR} = = > Serial port available ........... PASS${NC}"
    fi
    return 0
}

# Final anti-race gate used immediately adjacent to esptool device I/O.
#
# WHY THIS EXISTS:
# A shell serial monitor built as `while true; do cat /dev/ttyACM0; done` can create tiny gaps
# between successive `cat` processes. A single fuser/lsof sample can land in one of those gaps and
# incorrectly conclude that the port is free. Version 1.1.2 exposed exactly that race in physical
# testing.
#
# DESIGN RULE:
# - Require several consecutive FREE observations over a short interval.
# - Any BUSY observation aborts immediately and reports the holder when practical.
# - If occupancy detection is unavailable, fail closed.
# - On success, return directly to the caller; the caller must invoke esptool immediately, with no
#   menus, pauses, status screens, or other avoidable work inserted between this gate and esptool.
# - This narrows the race substantially; users must still treat the serial port as exclusively owned
#   by SnapFlash for the complete erase/write/read transaction.
ensure_serial_port_stably_free() {
    local samples=6
    local delay_seconds="0.15"
    local i rc

    for (( i=1; i<=samples; i++ )); do
        if serial_port_busy; then
            print_error "Serial Port Became Busy During The Final Pre-esptool Safety Window: $PORT"
            print_serial_port_holders
            print_warn "Close The Serial Monitor / Terminal Process And Try Again."
            print_warn "SnapFlash Will Not Kill The Process Automatically."
            return 1
        else
            rc=$?
        fi

        if (( rc == 2 )); then
            print_error "Cannot Verify Whether $PORT Is Already In Use."
            print_warn "Install/restore 'fuser' (psmisc) or provide 'lsof' before using device operations."
            return 1
        fi

        # No sleep after the final successful sample. The caller should launch esptool immediately.
        if (( i < samples )); then
            sleep "$delay_seconds"
        fi
    done

    return 0
}

normalize_mac() {
    printf '%s' "$1" | tr '[:lower:]' '[:upper:]'
}

probe_controller_mac() {
    local output mac

    [[ -e "$PORT" ]] || return 1
    [[ -x "$ESPTOOL" ]] || return 1

    # read-mac talks to the ESP ROM and does not write SPI flash. Supplying --chip esp32s3
    # makes an incompatible ESP family fail the probe instead of being accepted generically.
    if ! output=$("$ESPTOOL" --no-stub --chip esp32s3 --port "$PORT" read-mac 2>&1); then
        return 1
    fi

    mac=$(printf '%s\n' "$output" | grep -Eio '([0-9a-f]{2}:){5}[0-9a-f]{2}' | tail -n 1 || true)
    [[ -n "$mac" ]] || return 1

    CONTROLLER_MAC=$(normalize_mac "$mac")
    return 0
}

is_trusted_controller() {
    local mac="$1"
    [[ -f "$TRUSTED_DEVICES_FILE" ]] || return 1

    awk -v wanted="$(normalize_mac "$mac")" '
        /^[[:space:]]*#/ || NF == 0 { next }
        { mac=toupper($1); if (mac == wanted) { found=1; exit } }
        END { exit(found ? 0 : 1) }
    ' "$TRUSTED_DEVICES_FILE"
}

add_trusted_controller() {
    local mac="$1"
    local label="$2"

    if [[ ! -f "$TRUSTED_DEVICES_FILE" ]]; then
        {
            echo "# SNAPACK trusted ESP32-S3 controllers"
            echo "# MAC-address  Human-readable note"
        } > "$TRUSTED_DEVICES_FILE" || return 1
    fi

    printf '%s  %s\n' "$(normalize_mac "$mac")" "$label" >> "$TRUSTED_DEVICES_FILE"
}

controller_trust_gate() {
    local answer label

    clear_screen
    print_header "SNAPACK CONTROLLER CHECK"

    if [[ ! -e "$PORT" ]]; then
        echo -e "${RE} = = > Serial device .................. FAIL${NC}"
        echo -e "${GRAY} = = > ESP32-S3 communication ......... NOT AVAILABLE${NC}"
        echo
        print_error "No Flash-Capable SNAPACK Controller Is Currently Available."
        print_warn "Power And Connect The SNAPACK Controller And Try Again."
        pause_screen "Press Enter To Return To Main Menu..."
        clear_screen
        return 1
    fi

    echo -e "${GR} = = > Serial device .................. PASS${NC}"

    if ! ensure_serial_port_free visible; then
        echo
        print_error "Controller Check Stopped Before esptool Communication Was Attempted."
        pause_screen "Press Enter To Return To Main Menu..."
        clear_screen
        return 1
    fi

    if ! probe_controller_mac; then
        echo -e "${RE} = = > ESP32-S3 communication ......... FAIL${NC}"
        echo
        print_error "The Expected ESP32-S3 Did Not Respond To A Harmless esptool Probe."
        print_warn "No Firmware Or Device-Image Operation Was Attempted."
        pause_screen "Press Enter To Return To Main Menu..."
        clear_screen
        return 1
    fi

    echo -e "${GR} = = > ESP32-S3 communication ......... PASS${NC}"
    echo -e "${CY} = = > Controller MAC ................. ${GREEN}$CONTROLLER_MAC${NC}"

    if is_trusted_controller "$CONTROLLER_MAC"; then
        CONTROLLER_TRUST="TRUSTED"
        echo -e "${GR} = = > Trusted controller ............. PASS${NC}"
        echo
        print_good "Controller Is Present, Responsive, And Previously Approved."
        return 0
    fi

    CONTROLLER_TRUST="UNKNOWN"
    echo -e "${YE} = = > Trusted controller ............. UNKNOWN${NC}"
    echo
    print_warn "This ESP32-S3 Has Not Previously Been Approved For SNAPACK Flashing."
    print_warn "MAC Trust Is An Accidental-Flash Gate; It Does Not Prove Hardware Compatibility."
    echo
    echo -e "${YELLOW}     1) Approve And Add This Controller${NC}"
    echo -e "${YELLOW}     2) Continue This Time Without Saving${NC}"
    echo -e "${YELLOW}     3) Cancel Mission${NC}"

    while true; do
        echo
        echo -ne "${YELLOW} = = > Select Controller Action [1-3]: ${NC}${GREEN}"
        read -r answer
        echo -ne "${NC}"

        case "$answer" in
            1)
                echo -ne "${YELLOW} = = > Short Controller Note: ${NC}${GREEN}"
                read -r label
                echo -ne "${NC}"
                label=${label:-Approved SNAPACK controller}
                if ! add_trusted_controller "$CONTROLLER_MAC" "$label"; then
                    print_error "Could Not Update Trusted Controller Registry."
                    return 1
                fi
                CONTROLLER_TRUST="TRUSTED"
                print_good "Controller Approved And Added To Trusted Registry."
                return 0
                ;;
            2)
                CONTROLLER_TRUST="ONE-TIME"
                print_warn "Unknown Controller Accepted For This Mission Only."
                return 0
                ;;
            3)
                print_warn "Mission Cancelled. No Device Operation Was Attempted."
                pause_screen "Press Enter To Return To Main Menu..."
                clear_screen
                return 1
                ;;
            *)
                print_warn "Please Select 1, 2, Or 3."
                ;;
        esac
    done
}

quiet_final_controller_check() {
    local expected_mac="$CONTROLLER_MAC"

    if ! ensure_serial_port_free quiet; then
        print_error "Final Serial-Port Readiness Check Failed."
        print_error "DEVICE OPERATION REFUSED."
        return 1
    fi

    if ! probe_controller_mac; then
        print_error "Final Controller Readiness Check Failed."
        print_error "DEVICE OPERATION REFUSED."
        return 1
    fi

    # If the early gate saw a controller, refuse a last-second device swap.
    if [[ -n "$expected_mac" && "$(normalize_mac "$CONTROLLER_MAC")" != "$(normalize_mac "$expected_mac")" ]]; then
        print_error "Controller Changed After The Initial Trust Check."
        echo -e "${CYAN}       Expected MAC:${NC} ${YELLOW}$expected_mac${NC}"
        echo -e "${CYAN}       Current MAC:${NC}  ${YELLOW}$CONTROLLER_MAC${NC}"
        print_error "DEVICE OPERATION REFUSED."
        return 1
    fi

    return 0
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
    local mode="${2:-visible}"
    local file

    if [[ "$mode" != "quiet" ]]; then
        clear_screen
        print_header "FIRMWARE INTEGRITY CHECK"
        print_info "Archive: ${GREEN}$dir${NC}"
    fi

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

    if [[ "$mode" != "quiet" ]]; then
        echo
        print_info "Verifying SHA-256 Manifest..."
        echo
    fi

    if ! (
        cd "$dir"
        if [[ "$mode" == "quiet" ]]; then
            sha256sum -c SHA256SUMS >/dev/null
        else
            sha256sum -c SHA256SUMS
        fi
    ); then
        echo
        print_error "SHA-256 Verification Failed."
        print_error "FLASH REFUSED -- No Firmware Write Was Attempted."
        return 1
    fi

    if [[ "$mode" != "quiet" ]]; then
        echo
        print_good "SHA-256 Verification Passed For All Archived Firmware Files."
    fi
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
    if ! verify_firmware_archive "$dir" quiet; then
        return 1
    fi

    if ! quiet_final_controller_check; then
        return 1
    fi

    clear_screen
    print_header "SNAPACK FLASH ENGINE"
    print_info "Firmware Directory: ${GREEN}$dir${NC}"
    print_info "Target Port:        ${GREEN}$PORT${NC}"
    print_info "Chip:               ${GREEN}ESP32-S3${NC}"
    print_info "Flash Mode:         ${GREEN}DIO / 80 MHz / 16 MB${NC}"
    echo
    echo -e "${YEB} = = > FLASH WRITE STARTING -- DO NOT INTERRUP THE USB CONNECTION.${NC}"
    echo

    # Repeat the port-ownership check at the last practical instant. A serial monitor may have
    # been opened after the earlier controller/MAC gate. Refuse rather than allowing that race
    # to present as a mysterious esptool failure.
    if ! ensure_serial_port_stably_free; then
        print_error "Flash Write Refused By The Final Serial-Port Safety Gate."
        return 1
    fi

    # IMPORTANT: Keep esptool immediately adjacent to the sustained-free gate above.
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

    clear_screen
    print_header "FULL DEVICE IMAGE BACKUP"
    print_info "Proposed Operation:"
    echo -e "${CYAN}       Device:${NC}       ${GREEN}$PORT${NC}"
    echo -e "${CYAN}       Chip:${NC}         ${GREEN}ESP32-S3${NC}"
    echo -e "${CYAN}       Controller MAC:${NC} ${GREEN}$CONTROLLER_MAC${NC}"
    echo -e "${CYAN}       Trust Status:${NC}   ${GREEN}$CONTROLLER_TRUST${NC}"
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

    clear_screen
    print_header "READING COMPLETE ESP32-S3 FLASH"
    print_info "Destination: ${GREEN}$image_path${NC}"
    echo

    if ! quiet_final_controller_check; then
        print_error "Full Device Image Capture Refused By The Final Controller Check."
        rm -rf -- "$image_dir"
        return 1
    fi

    if ! ensure_serial_port_stably_free; then
        print_error "Device Image Read Refused By The Final Serial-Port Safety Gate."
        rm -rf -- "$image_dir"
        return 1
    fi

    # Keep esptool immediately adjacent to the sustained-free gate above.
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

    clear_screen
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
    local mode="${2:-visible}"
    local image_path="$dir/snapack_full_flash_16MB.bin"
    local actual_size

    if [[ "$mode" != "quiet" ]]; then
        clear_screen
        print_header "FULL DEVICE IMAGE INTEGRITY CHECK"
        print_info "Image Archive: ${GREEN}$dir${NC}"
    fi

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

    if [[ "$mode" != "quiet" ]]; then
        echo
        print_info "Verifying SHA-256 Manifest..."
        echo
    fi

    if ! (
        cd "$dir"
        if [[ "$mode" == "quiet" ]]; then
            sha256sum -c SHA256SUMS >/dev/null
        else
            sha256sum -c SHA256SUMS
        fi
    ); then
        echo
        print_error "Device Image SHA-256 Verification Failed."
        print_error "IMAGE RESTORE REFUSED."
        return 1
    fi

    if [[ "$mode" != "quiet" ]]; then
        echo
        print_good "Full Device Image Size And SHA-256 Verification Passed."
    fi
    return 0
}

flash_full_image() {
    local dir="$1"
    local image_path="$dir/snapack_full_flash_16MB.bin"

    # Just like the four-BIN engine, the complete-image write has an absolute integrity gate.
    if ! verify_full_flash_image "$dir" quiet; then
        return 1
    fi

    if ! quiet_final_controller_check; then
        return 1
    fi

    clear_screen
    print_header "FULL DEVICE IMAGE RESTORE ENGINE"
    print_info "Image Archive: ${GREEN}$dir${NC}"
    print_info "Target Port:   ${GREEN}$PORT${NC}"
    print_info "Write Range:   ${GREEN}0x00000000 - 0x00FFFFFF${NC}"
    print_info "Image Size:    ${GREEN}16 MiB${NC}"
    echo
    echo -e "${REB} = = > COMPLETE FLASH-DEVICE RESTORE STARTING.${NC}"
    echo -e "${YEB} = = > DO NOT INTERRUP THE USB CONNECTION.${NC}"
    echo

    if ! ensure_serial_port_stably_free; then
        print_error "Full Device Image Write Refused By The Final Serial-Port Safety Gate."
        return 1
    fi

    # Keep esptool immediately adjacent to the sustained-free gate above.
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

    clear_screen
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
# MARKER: RECOVERY ARCHIVE DELETION
# =========================================================================================
# PURPOSE:
# - Delete obsolete recovery material from the same selection area used for restoration.
# - Recovery directories are atomic units. Deletion removes the ENTIRE selected timestamped
#   directory so BIN/image payloads and their SHA256SUMS, INFO.txt, NOTES.txt, and STATUS
#   metadata cannot be separated into misleading scraps.
#
# SAFETY RULES:
# - Nothing is deleted without typing the exact word DELETE.
# - If .last_flash points at the selected recovery directory, the operator is warned before
#   confirmation. The stale state pointer is cleared only AFTER directory deletion succeeds.
# - A failed directory deletion leaves .last_flash untouched.
# =========================================================================================

delete_recovery_directory() {
    local selected="$1"
    local kind="$2"
    local status="UNKNOWN"
    local note=""
    local is_last_flash=0
    local last_archive=""
    local confirm

    [[ -d "$selected" ]] || {
        print_error "Selected Recovery Directory Does Not Exist."
        return 1
    }

    if [[ -f "$selected/STATUS" ]]; then
        status=$(cat "$selected/STATUS")
    fi
    note=$(get_archive_note "$selected")

    if [[ -f "$STATE_FILE" ]]; then
        if last_archive=$(cat "$STATE_FILE" 2>/dev/null) && [[ "$last_archive" == "$selected" ]]; then
            is_last_flash=1
        fi
    fi

    clear_screen
    print_header "SNAPACK DELETE RECOVERY ARCHIVE"
    print_info "Recovery Type: ${GREEN}$kind${NC}"
    print_info "Archive:       ${GREEN}$(basename "$selected")${NC}"
    if [[ -n "$note" ]]; then
        print_info "Description:   ${WHITE}$note${NC}"
    fi
    if [[ "$kind" == "Four-BIN Firmware" ]]; then
        print_info "Status:        $(format_status "$status")"
    fi
    echo
    echo -e "${REB} = = > WARNING: THE ENTIRE RECOVERY DIRECTORY WILL BE DELETED.${NC}"
    echo -e "${YE} = = > Payload Files And All SHA256SUMS / INFO / NOTES / STATUS Metadata In It Will Be Removed.${NC}"

    if (( is_last_flash == 1 )); then
        echo
        echo -e "${REB} = = > WARNING: THIS ARCHIVE IS RECORDED IN .last_flash AS THE MOST RECENT SUCCESSFUL DEVICE WRITE.${NC}"
        echo -e "${YE} = = > If Deletion Succeeds, SnapFlash Will Also Clear That Stale .last_flash Reference.${NC}"
    fi

    echo
    echo -ne "${YELLOW} = = > Type DELETE To Confirm, Or Press Enter To Cancel: ${NC}${GREEN}"
    read -r confirm
    echo -ne "${NC}"

    if [[ "$confirm" != "DELETE" ]]; then
        print_warn "Delete Cancelled. Nothing Was Removed."
        return 1
    fi

    if ! rm -rf -- "$selected"; then
        print_error "Recovery Directory Could Not Be Deleted."
        print_warn ".last_flash Was Not Changed."
        return 1
    fi

    if (( is_last_flash == 1 )); then
        if ! rm -f -- "$STATE_FILE"; then
            print_error "Archive Was Deleted, But .last_flash Could Not Be Cleared."
            print_warn "Manual Bookkeeping Repair Is Required."
            return 1
        fi
        print_warn ".last_flash Reference Was Cleared Because Its Recovery Archive Was Deleted."
    fi

    print_good "Recovery Archive Deleted Completely: $(basename "$selected")"
    return 0
}

delete_firmware_archive() {
    local archives=()
    local i status note number index selected

    mapfile -t archives < <(
        find "$ARCHIVE_DIR" -mindepth 1 -maxdepth 1 -type d | sort -r
    )

    if [[ ${#archives[@]} -eq 0 ]]; then
        print_warn "No Firmware Archives Are Available To Delete."
        return 1
    fi

    clear_screen
    print_header "DELETE FOUR-BIN FIRMWARE ARCHIVE"
    print_warn "Select An Archive For Deletion. No Deletion Occurs Until The Exact Word DELETE Is Entered."
    echo

    for i in "${!archives[@]}"; do
        status="UNKNOWN"
        [[ -f "${archives[$i]}/STATUS" ]] && status=$(cat "${archives[$i]}/STATUS")
        note=$(get_archive_note "${archives[$i]}")
        printf "${CYAN}%3d)${NC} ${GREEN}%-22s${NC} [%s]\n" \
            "$((i + 1))" "$(basename "${archives[$i]}")" "$(format_status "$status")"
        [[ -n "$note" ]] && echo -e "${CYAN}       Note:${NC} ${WHITE}$note${NC}"
    done

    echo
    echo -ne "${YELLOW} = = > Select Archive To Delete, Or 0 To Cancel: ${NC}${GREEN}"
    read -r number
    echo -ne "${NC}"

    [[ "$number" == "0" ]] && { print_warn "Delete Cancelled."; return 1; }
    [[ "$number" =~ ^[0-9]+$ ]] || { print_error "Invalid Selection: $number"; return 1; }
    index=$((number - 1))
    (( index >= 0 && index < ${#archives[@]} )) || { print_error "Archive Number Out Of Range: $number"; return 1; }
    selected="${archives[$index]}"

    delete_recovery_directory "$selected" "Four-BIN Firmware"
}

delete_full_device_image() {
    local images=()
    local i integrity number index selected

    mapfile -t images < <(
        find "$IMAGE_ARCHIVE_DIR" -mindepth 1 -maxdepth 1 -type d | sort -r
    )

    if [[ ${#images[@]} -eq 0 ]]; then
        print_warn "No Full Device Images Are Available To Delete."
        return 1
    fi

    clear_screen
    print_header "DELETE FULL DEVICE IMAGE"
    print_warn "Select An Image For Deletion. No Deletion Occurs Until The Exact Word DELETE Is Entered."
    echo

    for i in "${!images[@]}"; do
        if [[ -f "${images[$i]}/SHA256SUMS" ]]; then
            integrity="${GR}SHA-256${NC}"
        else
            integrity="${YE}UNVERIFIED${NC}"
        fi
        printf "${CYAN}%3d)${NC} ${GREEN}%-22s${NC} [%b]\n" \
            "$((i + 1))" "$(basename "${images[$i]}")" "$integrity"
    done

    echo
    echo -ne "${YELLOW} = = > Select Full Device Image To Delete, Or 0 To Cancel: ${NC}${GREEN}"
    read -r number
    echo -ne "${NC}"

    [[ "$number" == "0" ]] && { print_warn "Delete Cancelled."; return 1; }
    [[ "$number" =~ ^[0-9]+$ ]] || { print_error "Invalid Selection: $number"; return 1; }
    index=$((number - 1))
    (( index >= 0 && index < ${#images[@]} )) || { print_error "Image Number Out Of Range: $number"; return 1; }
    selected="${images[$index]}"

    delete_recovery_directory "$selected" "Full 16 MiB Device Image"
}

# =========================================================================================
# MARKER: FROZEN CLI BUILD / SOURCE PREFLIGHT (NEW IN 1.2.0)
# =========================================================================================
# The CLI must already be mounted. No auto-mount, install, download, or package updates.
# A failed build never falls through to stale IDE binaries.
source_preflight() {
    local sketch="$SKETCH_DIR/snapack.ino" count
    [[ -f "$sketch" ]] || { print_error "Missing sketch: $sketch"; return 1; }
    [[ -f "$SKETCH_DIR/README_PROTECTED_BEHAVIORS" || -f "$SKETCH_DIR/README_PROTECTED_BEHAVIORS.txt" || -f "$SKETCH_DIR/README_PROTECTED_BEHAVIORS.md" ]] || {
        print_error "Protected-behaviors README missing. Source gate refuses compilation."; return 1;
    }
    # Require exactly one active firmware step declaration; comments do not count.
    count=$(grep -Ec '^[[:space:]]*#define[[:space:]]+SNAPACK_FW_STEP[[:space:]]+' "$sketch" || true)
    [[ "$count" == 1 ]] || { print_error "Expected one SNAPACK_FW_STEP definition; found $count."; return 1; }
    # Local Wi-Fi credentials must remain local, never included in the source archive.
    return 0
}

# Capture source before compilation and compare the same source after compilation.
# This prevents a source archive from silently describing a later edit.
make_source_snapshot() {
    local output="$1"
    tar -C "$SKETCH_DIR" \
        --exclude='./recovery' --exclude='./build' --exclude='./.git' \
        --exclude='SNAPACK_LOCAL_ONLY_WIFI.h' \
        --exclude='*/SNAPACK_LOCAL_ONLY_WIFI.h' \
        -czf "$output" .
}

wifi_header_hash() {
    local header="$SKETCH_DIR/SNAPACK_LOCAL_ONLY_WIFI.h"
    if [[ -f "$header" ]]; then
        sha256sum "$header" | awk '{print $1}'
    else
        printf '%s\n' ABSENT
    fi
}

compile_isolated_build() {
    local result
    [[ -x "$CLI" ]] || {
        print_error "Frozen AppImage CLI unavailable: $CLI"
        print_warn "Mount the existing AppImage; do not install or update a replacement."
        return 1
    }
    source_preflight || return 1
    STAGED_BUILD=$(mktemp -d /tmp/snapflash-build.XXXXXX) || return 1
    STAGED_SOURCE="$STAGED_BUILD/source_before.tar.gz"
    make_source_snapshot "$STAGED_SOURCE" || {
        print_error "Could not snapshot source before compilation; FLASH REFUSED."
        return 1
    }
    STAGED_WIFI_HASH=$(wifi_header_hash) || return 1
    print_info "Isolated build: $STAGED_BUILD"
    print_info "Using the exact verified IDE board configuration."
    if "$CLI" compile --fqbn "$FQBN" --build-path "$STAGED_BUILD" --warnings none "$SKETCH_DIR" > "$STAGED_BUILD/compile.log" 2>&1; then
        tail -n 12 "$STAGED_BUILD/compile.log"
    else
        result=$?
        print_error "Compilation failed (exit $result); FLASH REFUSED."
        tail -n 35 "$STAGED_BUILD/compile.log"
        print_warn "Build log retained at $STAGED_BUILD/compile.log"
        return 1
    fi
    # Refuse a build whose source or local configuration changed mid-compile.
    if ! make_source_snapshot "$STAGED_BUILD/source_after.tar.gz" || \
       ! cmp -s "$STAGED_SOURCE" "$STAGED_BUILD/source_after.tar.gz" || \
       [[ "$STAGED_WIFI_HASH" != "$(wifi_header_hash)" ]]; then
        print_error "Source or local Wi-Fi configuration changed during compilation; FLASH REFUSED."
        print_warn "Build retained for inspection at $STAGED_BUILD"
        return 1
    fi
    local name
    for name in snapack.ino.bin snapack.ino.bootloader.bin snapack.ino.partitions.bin; do
        [[ -s "$STAGED_BUILD/$name" ]] || {
            print_error "Fresh build artifact missing/empty: $name; FLASH REFUSED."
            return 1
        }
    done
    BUILD_DIR="$STAGED_BUILD"
    BUILD_ORIGIN="Frozen AppImage CLI (isolated build)"
    return 0
}

# Store source and build provenance in addition to the existing four-BIN recovery unit.
# Source snapshot is created only for new CLI builds, not historical restore operations.
archive_build_provenance() {
    local dest="$1"
    [[ "$BUILD_ORIGIN" == "Frozen AppImage CLI (isolated build)" ]] || return 0
    [[ -f "$BUILD_DIR/compile.log" ]] || return 1
    cp -- "$BUILD_DIR/compile.log" "$dest/compile.log" || return 1
    # Preserve the exact snapshot captured BEFORE compilation, not a later source state.
    [[ -s "$STAGED_SOURCE" ]] || return 1
    cp -- "$STAGED_SOURCE" "$dest/source_snapshot.tar.gz" || return 1
    cmp -s "$STAGED_SOURCE" "$dest/source_snapshot.tar.gz" || return 1
    {
        echo "Build origin: $BUILD_ORIGIN"
        echo "CLI: $CLI"
        "$CLI" version
        echo "FQBN: $FQBN"
        echo "Source: $SKETCH_DIR"
        echo "Local Wi-Fi header SHA-256 (header excluded): $STAGED_WIFI_HASH"
        echo "Source snapshot captured before compilation and checked afterward."
        echo "Staging: $BUILD_DIR"
        echo "Source snapshot excludes recovery, build, .git and local-only Wi-Fi header."
    } > "$dest/BUILD_PROVENANCE.txt" || return 1
    (cd "$dest" && sha256sum compile.log source_snapshot.tar.gz BUILD_PROVENANCE.txt > SOURCE_SHA256SUMS && sha256sum -c SOURCE_SHA256SUMS >/dev/null) || return 1
}

# =========================================================================================
# MARKER: MAIN MENU
# =========================================================================================

print_target_splash

while true; do

# SCREEN OWNERSHIP RULE:
# Every return to the main menu begins on a clean terminal. Completed/cancelled subflows pause
# long enough to be read, then `continue` returns here and stale output is removed.
clear_screen
print_header "SNAPACK FIRMWARE UTILITY - VERSION 1.2.1"

echo -e "${YELLOW}     1) Compile, Archive And Flash (Frozen CLI)${NC}"
echo -e "${YELLOW}     2) Restore Archived Four-BIN Firmware${NC}"
echo -e "${YELLOW}     3) Restore Full 16 MB Device Image${NC}"
echo -e "${YELLOW}     4) Capture Full 16 MB Device Image${NC}"
echo -e "${YELLOW}     5) Exit${NC}"
echo -e "${YELLOW}     6) Archive And Flash Existing Arduino IDE Export (Fallback)${NC}"
echo
echo -e "${CYAN} = = > Build Source:${NC}   ${GREEN}$BUILD_DIR${NC}"
echo -e "${CYAN} = = > Archive Root:${NC}   ${GREEN}$ARCHIVE_DIR${NC}"
echo -e "${CYAN} = = > Image Root:${NC}     ${GREEN}$IMAGE_ARCHIVE_DIR${NC}"
echo -e "${CYAN} = = > Trust Registry:${NC} ${GREEN}$TRUSTED_DEVICES_FILE${NC}"
echo -e "${CYAN} = = > Flash Device:${NC}   ${GREEN}$PORT${NC}"
echo

echo -ne "${YELLOW} = = > Select Mission [1-6]: ${NC}${GREEN}"
read -r CHOICE
echo -ne "${NC}"

# Compile before entering the existing archive/flash path. A failed compilation cannot
# accidentally flash old IDE exports. Option 6 deliberately preserves the old path.
BUILD_DIR="$IDE_BUILD_DIR"
BUILD_ORIGIN="Arduino IDE export"
STAGED_BUILD=""
STAGED_SOURCE=""
STAGED_WIFI_HASH=""
if [[ "$CHOICE" == "1" ]]; then
    clear_screen
    print_header "ISOLATED SNAPACK COMPILATION"
    if ! compile_isolated_build; then
        pause_screen
        continue
    fi
elif [[ "$CHOICE" == "6" ]]; then
    CHOICE="1"
fi

case "$CHOICE" in

# =========================================================================================
# 1) ARCHIVE + FLASH NEW BUILD
# =========================================================================================

1)
    if ! controller_trust_gate; then
        continue
    fi

    if ! evaluate_previous_pending_flash; then
        pause_screen
        continue
    fi

    clear_screen
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

    clear_screen
    print_header "READY TO ARCHIVE + FLASH"
    print_info "Proposed Operation:"
    echo -e "${CYAN}       Build Source:${NC} ${GREEN}$BUILD_DIR${NC}"
    echo -e "${CYAN}       Archive Root:${NC} ${GREEN}$ARCHIVE_DIR${NC}"
    echo -e "${CYAN}       Flash Device:${NC} ${GREEN}$PORT${NC}"
    echo -e "${CYAN}       Chip:${NC}         ${GREEN}ESP32-S3${NC}"
    echo -e "${CYAN}       Controller MAC:${NC} ${GREEN}$CONTROLLER_MAC${NC}"
    echo -e "${CYAN}       Trust Status:${NC}   ${GREEN}$CONTROLLER_TRUST${NC}"
    echo
    echo -e "${YE} = = > The Current Arduino Build Will First Be Archived.${NC}"
    echo -e "${YE} = = > The Archived Copies Will Then Be Flashed To The Controller.${NC}"
    echo -e "${YE} = = > No Archive Directory Or Flash Write Has Started Yet.${NC}"
    echo

    # Ask for descriptive metadata BEFORE the final commitment. Keep it only in memory until
    # the operator presses Enter. Ctrl+C at the commitment prompt therefore leaves no archive
    # directory, NOTES.txt, or other debris behind.
    ARCHIVE_NOTE=""
    echo -ne "${YELLOW} = = > Add A Short Human-Readable Description To This Archive? [y/N]: ${NC}${GREEN}"
    read -r ADD_NOTE
    echo -ne "${NC}"
    ADD_NOTE=${ADD_NOTE:-N}

    if [[ "$ADD_NOTE" =~ ^[Yy]$ ]]; then
        echo -ne "${YELLOW} = = > Description: ${NC}${GREEN}"
        read -r ARCHIVE_NOTE
        echo -ne "${NC}"
    fi

    echo
    if [[ -n "$ARCHIVE_NOTE" ]]; then
        print_info "Description To Save: ${WHITE}$ARCHIVE_NOTE${NC}"
    else
        print_info "Description To Save: ${GRAY}(none)${NC}"
    fi
    echo
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

    # -------------------------------------------------------------------------
    # PRE-FLASH ARCHIVE VERIFICATION
    # -------------------------------------------------------------------------
    # Perform the fast verification work without spraying several separate screens across
    # the terminal. The operator receives one consolidated PASS/FAIL page after the work
    # completes. The actual flash engine still repeats the critical integrity and controller
    # gates quietly immediately before writing.
    COPY_CHECK_FAILED=0

    cmp -s "$BUILD_DIR/snapack.ino.bootloader.bin" "$NEW_ARCHIVE/snapack.ino.bootloader.bin" || COPY_CHECK_FAILED=1
    cmp -s "$BUILD_DIR/snapack.ino.partitions.bin" "$NEW_ARCHIVE/snapack.ino.partitions.bin" || COPY_CHECK_FAILED=1
    cmp -s "$BOOT_APP0" "$NEW_ARCHIVE/boot_app0.bin" || COPY_CHECK_FAILED=1
    cmp -s "$BUILD_DIR/snapack.ino.bin" "$NEW_ARCHIVE/snapack.ino.bin" || COPY_CHECK_FAILED=1

    if (( COPY_CHECK_FAILED != 0 )); then
        clear_screen
        print_header "SNAPACK PRE-FLASH VERIFICATION"
        echo -e "${GR} = = > Required firmware files ........ PASS${NC}"
        echo -e "${GR} = = > Archive directory created ...... PASS${NC}"
        echo -e "${RE} = = > Archived copies verified ....... FAIL${NC}"
        echo -e "${GRAY} = = > SHA-256 manifest generated ..... NOT RUN${NC}"
        echo -e "${GRAY} = = > Firmware integrity check ....... NOT RUN${NC}"
        echo
        print_error "Archive Creation Failed -- FLASH REFUSED."
        print_warn "Incomplete Archive Will Be Removed."
        rm -rf -- "$NEW_ARCHIVE"
        pause_screen
        continue
    fi

    if ! (
        cd "$NEW_ARCHIVE"
        sha256sum \
            snapack.ino.bootloader.bin \
            snapack.ino.partitions.bin \
            boot_app0.bin \
            snapack.ino.bin \
            > SHA256SUMS
    ); then
        clear_screen
        print_header "SNAPACK PRE-FLASH VERIFICATION"
        echo -e "${GR} = = > Required firmware files ........ PASS${NC}"
        echo -e "${GR} = = > Archive directory created ...... PASS${NC}"
        echo -e "${GR} = = > Archived copies verified ....... PASS${NC}"
        echo -e "${RE} = = > SHA-256 manifest generated ..... FAIL${NC}"
        echo -e "${GRAY} = = > Firmware integrity check ....... NOT RUN${NC}"
        echo
        print_error "Could Not Generate SHA256SUMS -- FLASH REFUSED."
        rm -rf -- "$NEW_ARCHIVE"
        pause_screen
        continue
    fi

    if ! verify_firmware_archive "$NEW_ARCHIVE" quiet; then
        clear_screen
        print_header "SNAPACK PRE-FLASH VERIFICATION"
        echo -e "${GR} = = > Required firmware files ........ PASS${NC}"
        echo -e "${GR} = = > Archive directory created ...... PASS${NC}"
        echo -e "${GR} = = > Archived copies verified ....... PASS${NC}"
        echo -e "${GR} = = > SHA-256 manifest generated ..... PASS${NC}"
        echo -e "${RE} = = > Firmware integrity check ....... FAIL${NC}"
        echo
        print_error "New Archive Did Not Pass Its Own Integrity Check -- FLASH REFUSED."
        rm -rf -- "$NEW_ARCHIVE"
        pause_screen
        continue
    fi

    # INFO.txt is plain text and ANSI-free so the archive remains self-describing outside
    # this utility. It is descriptive metadata and is not part of the firmware hash set.
    {
        echo "SNAPACK firmware archive"
        echo "Created: $(date)"
        echo
        echo "Original build directory:"
        echo "$BUILD_DIR"
        echo "Build origin: $BUILD_ORIGIN"
        echo "FQBN: ${FQBN:-not recorded}"
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

    # Optional human description was collected on the Proposed Operation screen before the
    # final commit. It becomes persistent only now that the archive really exists. NOTES.txt
    # remains deliberately outside SHA256SUMS so metadata edits do not alter firmware identity.
    if [[ -n "$ARCHIVE_NOTE" ]]; then
        if ! printf '%s\n' "$ARCHIVE_NOTE" > "$NEW_ARCHIVE/NOTES.txt"; then
            print_error "Could Not Write NOTES.txt."
            print_warn "Firmware Archive Remains Valid; Description Was Not Saved."
            ARCHIVE_NOTE=""
        fi
    fi

    # No new CLI build is flashable without its source snapshot and compile provenance.
    if ! archive_build_provenance "$NEW_ARCHIVE"; then
        print_error "Source/build provenance archive failed -- FLASH REFUSED."
        print_warn "Incomplete archive retained for inspection: $NEW_ARCHIVE"
        pause_screen
        continue
    fi

    clear_screen
    print_header "SNAPACK PRE-FLASH VERIFICATION"
    echo -e "${GR} = = > Required firmware files ........ PASS${NC}"
    echo -e "${GR} = = > Archive directory created ...... PASS${NC}"
    echo -e "${GR} = = > Archived copies verified ....... PASS${NC}"
    echo -e "${GR} = = > SHA-256 manifest generated ..... PASS${NC}"
    echo -e "${GR} = = > Firmware integrity check ....... PASS${NC}"
    echo -e "${GR} = = > ESP32-S3 communication ......... PASS${NC}"
    echo -e "${GR} = = > Initial controller check ......... PASS${NC}"
    echo
    print_info "Archive:        ${GREEN}$NEW_ARCHIVE${NC}"
    print_info "Controller MAC: ${GREEN}$CONTROLLER_MAC${NC}"
    print_info "Trust Status:   ${GREEN}$CONTROLLER_TRUST${NC}"
    if [[ -n "$ARCHIVE_NOTE" ]]; then
        print_info "Description:    ${WHITE}$ARCHIVE_NOTE${NC}"
    fi
    echo
    print_good "ARCHIVE VERIFIED AND READY TO FLASH"
    print_warn "No Firmware Has Been Written Yet."
    pause_screen "Press Enter To Continue To The Flash Engine..."

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
    if ! controller_trust_gate; then
        continue
    fi

    if ! evaluate_previous_pending_flash; then
        pause_screen
        continue
    fi

    clear_screen
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
    echo -e "${YELLOW}     D) Delete A Firmware Archive${NC}"
    echo -e "${YELLOW}     0) Return To Main Menu${NC}"
    echo
    echo -ne "${YELLOW} = = > Select Archive To Restore: ${NC}${GREEN}"
    read -r NUMBER
    echo -ne "${NC}"

    if [[ "$NUMBER" == "0" ]]; then
        continue
    fi

    if [[ "$NUMBER" =~ ^[Dd]$ ]]; then
        if delete_firmware_archive; then
            pause_screen
        else
            pause_screen
        fi
        continue
    fi

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

    clear_screen
    print_header "READY TO RESTORE + FLASH"
    print_info "Proposed Operation:"
    echo -e "${CYAN}       Archive:${NC}      ${GREEN}$(basename "$SELECTED")${NC}"
    if [[ -n "$SELECTED_NOTE" ]]; then
        echo -e "${CYAN}       Description:${NC}  ${WHITE}$SELECTED_NOTE${NC}"
    else
        echo -e "${CYAN}       Description:${NC}  ${GRAY}(none)${NC}"
    fi
    echo -e "${CYAN}       Status:${NC}       $(format_status "$STATUS")"
    echo -e "${CYAN}       Flash Device:${NC} ${GREEN}$PORT${NC}"
    echo -e "${CYAN}       Chip:${NC}         ${GREEN}ESP32-S3${NC}"
    echo -e "${CYAN}       Controller MAC:${NC} ${GREEN}$CONTROLLER_MAC${NC}"
    echo -e "${CYAN}       Trust Status:${NC}   ${GREEN}$CONTROLLER_TRUST${NC}"
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

    clear_screen
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
    if ! controller_trust_gate; then
        continue
    fi

    if ! evaluate_previous_pending_flash; then
        pause_screen
        continue
    fi

    clear_screen
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
    echo -e "${YELLOW}     D) Delete A Full Device Image${NC}"
    echo -e "${YELLOW}     0) Return To Main Menu${NC}"
    echo
    echo -ne "${YELLOW} = = > Select Full Device Image To Restore: ${NC}${GREEN}"
    read -r NUMBER
    echo -ne "${NC}"

    if [[ "$NUMBER" == "0" ]]; then
        continue
    fi

    if [[ "$NUMBER" =~ ^[Dd]$ ]]; then
        if delete_full_device_image; then
            pause_screen
        else
            pause_screen
        fi
        continue
    fi

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

    clear_screen
    print_header "READY TO RESTORE COMPLETE DEVICE IMAGE"
    print_info "Selected Image:  ${GREEN}$(basename "$SELECTED_IMAGE")${NC}"
    print_info "Flash Device:    ${GREEN}$PORT${NC}"
    print_info "Controller MAC:  ${GREEN}$CONTROLLER_MAC${NC}"
    print_info "Trust Status:    ${GREEN}$CONTROLLER_TRUST${NC}"
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

    clear_screen
    print_header "FULL DEVICE IMAGE RESTORE COMPLETE"
    print_good "Complete 16 MiB Device Image Restored Successfully."
    print_info "Installed Image: ${GREEN}$(basename "$SELECTED_IMAGE")${NC}"
    pause_screen
    ;;

# =========================================================================================
# 4) CAPTURE FULL DEVICE IMAGE
# =========================================================================================

4)
    if ! controller_trust_gate; then
        continue
    fi

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
