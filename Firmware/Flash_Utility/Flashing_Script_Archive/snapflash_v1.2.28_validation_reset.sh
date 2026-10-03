#!/bin/bash

# VERSION NOTE:
# The SNAPACK Recovery Storage Directory Was Renamed From Archive To Recovery.
# Older Utility Versions Expect The Archive Directory While Version 1.0.0 And Later Expect Recovery.
# Firmware Behavior And Flash Addresses Were Not Changed.

# =========================================================================================
# SNAPACK FIRMWARE ARCHIVE / FLASH / RESTORE UTILITY
# VERSION: 1.2.28
# =========================================================================================
# PURPOSE:
# - Archive Every Newly Exported SNAPACK Firmware Build BEFORE It Is Flashed.
# - Keep The Exact Four-File ESP32-S3 Flash Set Together As One Restorable Unit.
# - Remember Which Archived Version Was Flashed Most Recently.
# - Ask Before The NEXT Write Operation Whether The Previously Flashed Firmware Proved GOOD Or BAD.
# - Restore Any Retained Four-BIN Firmware Archive Without Rebuilding Old Source Code.
# - Capture, Verify, And Restore Complete 16 MiB Device Images As A Second Recovery Path.
#
# WORKFLOW PHILOSOPHY:
# - The Archive Copy Is The Authority For The Flash Operation.
# - A Newly Written Four-BIN Version Becomes PENDING Only AFTER Esptool Reports Success.
# - BAD Means "Known Bad In Physical Testing"; It Is Retained, Not Silently Deleted.
# - Restores Flash The Archived Binaries/Images Exactly As They Were Preserved.
#
# IMPORTANT:
# - Option 1 Compiles With The Existing Gear Lever AppImage CLI Into Isolated Staging.
# - Option 3 Retains The Established Arduino IDE Export Compiled Binary Fallback.
# - Option 6 Resumes An Existing Verified Archive Without Compiling Or Archiving.
# - Both Options Flash Only Verified Archived Copies With Esptool.
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
CYB=$'\033[5;36m'

WHITE=$'\033[1;37m'
BW=$'\033[1;37m'

GRAY=$'\033[0;37m'
DIM=$'\033[2m'
NC=$'\033[0m'

# =========================================================================================
# MARKER: PATHS / FLASH CONSTANTS
# =========================================================================================
# BUILD_DIR:
# - Arduino IDE Export/Build Output Currently Used By SNAPACK.
#
# ARCHIVE_DIR:
# - Permanent Timestamped Firmware Archive.
#
# BOOT_APP0:
# - Arduino ESP32 Core Boot_App0 Binary Required For The Established Flash Layout.
#
# ESPTOOL / PORT:
# - Known Working Command-Line Esptool Path And SNAPACK USB Serial Device.
# =========================================================================================

BUILD_DIR="/home/valued/Arduino/snapack/build/esp32.esp32.esp32s3"
ARCHIVE_DIR="/home/valued/Arduino/snapack/recovery/bin_backup"
IMAGE_ARCHIVE_DIR="/home/valued/Arduino/snapack/recovery/device_images"
TRUSTED_DEVICES_FILE="/home/valued/Arduino/snapack/recovery/trusted_devices.txt"

BOOT_APP0="/home/valued/.arduino15/packages/esp32/hardware/esp32/2.0.14/tools/partitions/boot_app0.bin"

ESPTOOL="$HOME/.local/bin/esptool"
PORT="/dev/ttyACM0"

# Frozen, Verified IDE-Equivalent Compilation Configuration. Do Not Auto-Install Or Update Anything.
SKETCH_DIR="/home/valued/Arduino/snapack"
UI_LIB_DIR="/home/valued/Arduino/libraries/UI"
# Gear Lever managed, stable AppImage path. Never retain /tmp/.mount_* paths.
ARDUINO_APPIMAGE="/home/valued/Appimages/arduino_ide.appimage"
CLI=""
APPIMAGE_EXTRACT_DIR=""
FQBN='esp32:esp32:esp32s3:UploadSpeed=460800,USBMode=hwcdc,CDCOnBoot=cdc,MSCOnBoot=default,DFUOnBoot=default,UploadMode=default,CPUFreq=240,FlashMode=qio,FlashSize=16M,PartitionScheme=huge_app,DebugLevel=none,PSRAM=opi,LoopCore=1,EventsCore=1,EraseFlash=none,JTAGAdapter=default'
IDE_BUILD_DIR="$BUILD_DIR"
BUILD_ORIGIN="Arduino IDE export"
STAGED_BUILD=""
STAGED_SOURCE=""
STAGED_WIFI_HASH=""
VALIDATION_LOG=""
RELEASE_STEP=""
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
# - Each Major SnapFlash View Owns A Clean Terminal Screen.
# - Information That Must Remain Visible Ends With An Enter Acknowledgment.
# - After Acknowledgment, The Next Major View Clears Stale Output Before Drawing Itself.
# - This Prevents Delete/Restore/Verification Remnants From Accumulating Above Later Menus.
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
    # Keep Screen Transitions Deliberate. `Clear` Is Preferred, But Fall Back To ANSI Home/Clear
    # If The Terminal Database Is Unavailable For Some Reason.
    if ! clear 2>/dev/null; then
        printf '\033[2J\033[H'
    fi
}

# Return A Colored Status Without Changing The STATUS File Itself.
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

# Return The First Archive Note Line, Or An Empty String When No Note Exists.
# NOTES.Txt Is Deliberately NOT Part Of SHA256SUMS: It Is Descriptive Metadata That May Be
# Added Or Edited Without Changing The Cryptographic Identity Of The Firmware BINs.
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
# - Make The Intended Hardware Target Visible Every Time The Utility Starts.
# - This Is Deliberately A Standalone Splash Page With An Enter Gate. The Warning Remains
#   Visible By Itself Until Acknowledged, Then The Terminal Is Cleared Before The Main Menu.
#
# IMPORTANT FOR FUTURE USERS:
# - These Archives Contain A Board-Specific ESP32-S3 Flash Layout. A Valid Hash Proves That
#   An Archive Has Not Changed; It Does NOT Prove That The Archive Belongs On Arbitrary
#   Hardware. Integrity And Hardware Compatibility Are Separate Requirements.
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
# - Do Not Let A Device-Dependent Mission Proceed When No ESP32-S3 Is Actually Available.
# - Refuse Early If Another Process Already Owns The Configured Serial Port. A Terminal Monitor
#   Running Inside A Shell `While True` Loop Is One Important Example Of This Failure Mode.
# - Read The Controller Base MAC With Esptool Before Archive Selection Or Other Mission Work.
# - Compare That MAC With A Deliberately Maintained Trusted-Controller Registry.
# - Unknown Controllers Are NEVER Enrolled Silently.
#
# TRUST MODEL:
# - A Known MAC Means This Individual Controller Was Previously Approved For SNAPACK Work.
# - An Unknown MAC May Be Approved And Saved, Used Once Without Saving, Or Rejected.
# - MAC Trust Does NOT Prove Board-Model Compatibility; The Startup Hardware Warning Remains
#   Authoritative For That Separate Question.
#
# SERIAL-PORT SAFETY RULE:
# - The Readiness Order Is: Device Node Exists -> Serial Port Is Free -> ESP32-S3 Responds ->
#   MAC Is Read -> Trusted-Controller Status Is Checked.
# - If Another Process Owns The Port, Show Its PID/Command When Practical And REFUSE The Mission.
# - SnapFlash Never Kills The Occupying Process Automatically; The Operator Decides What To Close.
#
# FINAL SAFETY RULE:
# - A Second Quiet Communication/MAC Check Occurs Before Every Device Operation. This Catches A
#   Controller That Was Disconnected, Powered Down, Or Replaced After The Early Mission Gate.
# - Port Occupancy Is Checked Again Immediately Before The Actual Read/Write Command So A Serial
#   Monitor Started After The Initial Gate Does Not Turn Into An Unexplained Esptool Failure.
# =========================================================================================

CONTROLLER_MAC=""
CONTROLLER_TRUST="UNKNOWN"

# Return Success When The Configured Serial Port Is Currently Held By Another Process.
# Return 1 When The Port Appears Free. Return 2 When No Supported Occupancy Detector Exists.
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

# Best-Effort Diagnostics Only. Failure To Identify The Holder Does Not Weaken The Busy-Port Gate.
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
            echo "# MAC-address  Note"
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
    local file asset_mode=0 expected_count=4 layout_doc=""
    [[ ! -e "$dir/FAILED_VERIFICATION.txt" ]] || { print_error "Archive is quarantined after failed verification"; return 1; }
    # STEP91Y_ASSETS is read-only compatibility for archives created by v1.2.24.
    # New archives use SNAPAS1_ASSETS_V1; retire the old marker only after old
    # archives are explicitly migrated and their hashes reverified.
    if [[ -e "$dir/RELEASE_FORMAT" ]]; then
        [[ -f "$dir/RELEASE_FORMAT" && ! -L "$dir/RELEASE_FORMAT" ]] && [[ "$(cat "$dir/RELEASE_FORMAT")" == SNAPAS1_ASSETS_V1 || "$(cat "$dir/RELEASE_FORMAT")" == STEP91Y_ASSETS ]] || { print_error "Invalid archive format marker"; return 1; }
        asset_mode=1; expected_count=8
        if [[ "$(cat "$dir/RELEASE_FORMAT")" == SNAPAS1_ASSETS_V1 ]]; then
            local docs=("$dir"/assets/ASSET_LAYOUT_*.txt)
            [[ ${#docs[@]} -eq 1 && -f "${docs[0]}" && ! -L "${docs[0]}" ]] || { print_error "New-format archive requires exactly one asset layout document"; return 1; }
            layout_doc="assets/${docs[0]##*/}"
            expected_count=9
        fi
    elif [[ -e "$dir/assets/snapack_assets.bin" || -e "$dir/partitions.csv" || -e "$dir/assets/ASSET_MANIFEST_SHA256.txt" ]]; then
        print_error "Unmarked asset archive refused"; return 1
    fi

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

    if (( asset_mode )); then
        for file in assets/snapack_assets.bin partitions.csv assets/ASSET_MANIFEST_SHA256.txt RELEASE_FORMAT; do
            [[ -f "$dir/$file" && ! -L "$dir/$file" ]] || { print_error "Missing asset archive component: $file"; return 1; }
        done
    fi
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
    if [[ $(wc -l < "$dir/SHA256SUMS") -ne $expected_count ]]; then
        print_error "SHA256SUMS Does Not Contain Expected Number Of Firmware/Asset Entries."
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

    if (( asset_mode )); then
        for file in assets/snapack_assets.bin partitions.csv assets/ASSET_MANIFEST_SHA256.txt RELEASE_FORMAT ${layout_doc:+"$layout_doc"}; do
            [[ $(awk -v name="$file" '$2 == name {count++} END {print count+0}' "$dir/SHA256SUMS") -eq 1 ]] || return 1
        done
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
        print_error "SHA-256 Verification Failed."
        print_error "FLASH REFUSED -- No Firmware Write Was Attempted."
        return 1
    fi

    if (( asset_mode )); then
        if [[ -n "$layout_doc" ]]; then
            snapflash_contract assets "$dir" || return 1
        else
            snapflash_contract assets-legacy-archive "$dir" || return 1
        fi
        snapflash_contract partition-csv "$dir/partitions.csv" || return 1
        snapflash_contract partition-bin "$dir/snapack.ino.partitions.bin" assets || return 1
        local app_bytes
        app_bytes=$(stat -c %s "$dir/snapack.ino.bin") || return 1
        (( app_bytes <= 0x9F0000 )) || { print_error "Archived app exceeds asset-layout app partition"; return 1; }
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
    local asset_args=()

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
    echo -e "${YEB} = = > FLASH WRITE STARTING -- DO NOT INTERRUPT THE USB CONNECTION.${NC}"
    echo

    if [[ -f "$dir/RELEASE_FORMAT" ]]; then asset_args=(0xA00000 "$dir/assets/snapack_assets.bin"); fi
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
        0x10000 "$dir/snapack.ino.bin" \
        "${asset_args[@]}"
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
    echo -e "${YEB} = = > DO NOT INTERRUPT THE USB CONNECTION.${NC}"
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
# - Nothing Is Deleted Without Entering The Exact Four-Digit Confirmation Code 1234.
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
    print_info "Confirmation Code: ${GREEN}1234${NC} (0 = Cancel)"
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
    echo -ne "${YELLOW} = = > Enter 1234 To Confirm, Or 0 To Cancel:  ${NC}${GREEN}"
    read -r confirm
    echo -ne "${NC}"

    if [[ "$confirm" != "1234" ]]; then
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
    print_warn "Select An Archive For Deletion. No Deletion Occurs Until The Exact Code 1234 Is Entered."
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
    print_warn "Select An Image For Deletion. No Deletion Occurs Until The Exact Code 1234 Is Entered."
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

# Permanent SNAPACK contract v1 engine; data-only release ZIPs, no executable release validators.
snapflash_contract() {
    python3 - "$@" <<'SNAPFLASH_CONTRACT_PY'
import sys, os, re, hashlib, pathlib, zipfile, tempfile, shutil, stat, time
from pathlib import Path

def reject(msg): raise ValueError(msg)
def safe(p):
    if not p or '\\' in p or p.startswith('/') or re.match(r'^[A-Za-z]:',p) or any(x in ('','.','..') for x in p.split('/')): reject('unsafe path: '+repr(p))
    if p == 'SNAPACK_LOCAL_ONLY_WIFI.h' or p.endswith('/SNAPACK_LOCAL_ONLY_WIFI.h'): reject('private Wi-Fi header in package/manifest')
    return p

def regular(path):
    if path.is_symlink() or not path.is_file(): reject('not a regular file: '+str(path))

def manifest(path):
    regular(path); out={}
    for i,line in enumerate(path.read_text().splitlines(),1):
        m=re.fullmatch(r'([0-9a-fA-F]{64}) [ *](.+)',line)
        if not m: reject(f'invalid SHA-256 manifest line {path}:{i}')
        key=safe(m[2]);
        if key in out: reject('duplicate manifest path: '+key)
        if not (key in ('snapack.ino','partitions.csv') or (key.startswith('ui/') and key.endswith(('.ino','.h','.c','.cpp','.hpp'))) or re.fullmatch(r'[^/]+\.(?:h|c|cpp|hpp)',key)): reject('invalid firmware source path: '+key)
        out[key]=m[1].lower()
    if not out or 'snapack.ino' not in out: reject('source manifest missing snapack.ino')
    return out

def digest(p):
    h=hashlib.sha256()
    with p.open('rb') as f:
        for chunk in iter(lambda:f.read(1024*1024),b''):h.update(chunk)
    return h.hexdigest()

# Fixed SNAPACK 16 MiB partition contract. This is not applied to historical BIN restores.
PARTITIONS = {
    'nvs': ('data','nvs',0x9000,0x5000,1,2),
    'otadata': ('data','ota',0xe000,0x2000,1,0),
    'app0': ('app','ota_0',0x10000,0xff0000,0,16),
}
# Layout is a validated package contract, not a firmware STEP identity.
# SNAPAS1 v1 currently specifies a 6 MiB asset region at 0xA00000.
# This is a FORMAT contract, not a STEP lock. To change it, introduce a new
# validated format/layout and keep the old decoder for archived restores.
PARTITIONS_ASSETS = {**PARTITIONS, 'app0': ('app','ota_0',0x10000,0x9f0000,0,16), 'assets': ('data','0x40',0xa00000,0x600000,1,0x40)}

def asset_mode(root):
    folder=root/'assets'
    if not folder.exists():return False
    if not folder.is_dir() or folder.is_symlink():reject('unsafe asset directory')
    return True

def expected_partitions(root=None):
    return PARTITIONS_ASSETS if root is not None and asset_mode(root) else PARTITIONS

def verify_assets(root,legacy_archive=False):
    import struct
    if not asset_mode(root):reject('asset package directory missing')
    payload=root/'assets/snapack_assets.bin';mf=root/'assets/ASSET_MANIFEST_SHA256.txt'
    regular(payload);regular(mf)
    lines=mf.read_text().splitlines()
    if len(lines)!=1 or not re.fullmatch(r'[0-9a-f]{64}  snapack_assets\.bin',lines[0]):reject('invalid asset SHA manifest')
    expected_sha=lines[0][:64]
    if digest(payload)!=expected_sha:reject('asset SHA-256 mismatch')
    size=payload.stat().st_size
    if size<20 or size>0x600000:reject('asset payload outside partition capacity')
    with payload.open('rb') as f:header=f.read(20)
    if header[:8]!=b'SNAPAS1\0':reject('unknown asset format (expected SNAPAS1)')
    version,count,declared_size=struct.unpack_from('<III',header,8)
    if version!=1 or not 1<=count<=1024 or declared_size!=size:reject('invalid asset format version, entry count or length')
    layout_files=list((root/'assets').glob('ASSET_LAYOUT_*.txt'))
    allowed={payload.name,mf.name} | {p.name for p in layout_files}
    if {p.name for p in (root/'assets').iterdir()}!=allowed:reject('unexpected asset package component')
    if len(layout_files)!=1 and not (legacy_archive and len(layout_files)==0):reject('expected exactly one asset layout description')
    if layout_files:regular(layout_files[0])
    if layout_files and root.joinpath('validation/RELEASE_INFO.txt').is_file():
        release=readinfo(root)['RELEASE']
        if layout_files[0].name!='ASSET_LAYOUT_'+release+'.txt':reject('asset layout document does not match release identity')
    print(f'PASS: SNAPAS1 v{version}, {count} entries, {size} bytes; asset SHA-256 verified')
    return size

def partition_csv(path):
    regular(path)
    expected_layout=expected_partitions(path.parent)
    rows={}
    for i,line in enumerate(path.read_text().splitlines(),1):
        line=line.strip()
        if not line or line.startswith('#'):continue
        cells=[c.strip() for c in line.split(',')]
        if len(cells)!=6 or cells[5]:reject(f'invalid partitions.csv line {i}')
        name,typ,sub,offset,size,_=cells
        if name in rows:reject('duplicate partition: '+name)
        try:off=int(offset,0);sz=int(size,0)
        except ValueError:reject(f'invalid partition number at line {i}')
        rows[name]=(typ,sub,off,sz)
    if set(rows)!=set(expected_layout):reject('partition names differ from required SNAPACK layout')
    ranges=[]
    for name,(typ,sub,off,sz) in rows.items():
        expected=expected_layout[name]
        if (typ,sub,off,sz)!=expected[:4]:reject('partition layout mismatch: '+name)
        if off<0x9000 or off+sz>0x1000000 or sz<=0:reject('partition outside flash: '+name)
        if off % (0x10000 if typ=='app' else 0x1000):reject('partition misaligned: '+name)
        ranges.append((off,off+sz,name))
    ranges.sort()
    if any(a[1]>b[0] for a,b in zip(ranges,ranges[1:])):reject('overlapping partitions')
    return rows

def partition_bin(path, asset_mode=False):
    regular(path)
    expected_layout=PARTITIONS_ASSETS if asset_mode else PARTITIONS
    data=path.read_bytes()
    if not data or len(data)>0x1000:reject('invalid generated partition binary size')
    import struct
    rows={}; ended=False
    for pos in range(0,len(data),32):
        item=data[pos:pos+32]
        if len(item)<32:reject('truncated partition binary')
        if item==b'\xff'*32:
            ended=True;continue
        magic=struct.unpack_from('<H',item)[0]
        if magic==0xebeb: # Optional ESP-IDF MD5 checksum entry.
            ended=True;continue
        if ended or magic!=0x50aa:reject('invalid generated partition entry')
        typ,sub,off,sz=struct.unpack_from('<BBII',item,2)
        name=item[12:28].split(b'\0',1)[0].decode('ascii')
        if name in rows:reject('duplicate generated partition: '+name)
        rows[name]=(typ,sub,off,sz)
    if set(rows)!=set(expected_layout):reject('generated partition names mismatch')
    for name,expected in expected_layout.items():
        if rows[name]!=(expected[4],expected[5],expected[2],expected[3]):reject('generated partition mismatch: '+name)
    print('PASS: Generated partition binary matches SNAPACK 16 MiB layout')

def readinfo(root):
    p=root/'validation/RELEASE_INFO.txt';regular(p); data={}
    for line in p.read_text().splitlines():
        if not line or line.startswith('#'):continue
        if line.count('=')!=1:reject('invalid release info line: '+line)
        k,v=line.split('=',1)
        if k in data:reject('duplicate release key: '+k)
        data[k]=v
    if set(data)!={'FORMAT_VERSION','RELEASE','BASELINE'} or data['FORMAT_VERSION']!='1' or not re.fullmatch(r'STEP[A-Za-z0-9_]+',data['RELEASE']) or not re.fullmatch(r'STEP[A-Za-z0-9_]+',data['BASELINE']):reject('invalid RELEASE_INFO.txt')
    return data

def validate(root,allow_extra=False):
    info=readinfo(root); src=manifest(root/'validation/SOURCE_MANIFEST_SHA256.txt'); base=manifest(root/'validation/BASELINE_SHA256.txt')
    if 'partitions.csv' not in src:reject('source manifest missing required sketch-root partitions.csv')
    if asset_mode(root):verify_assets(root)
    partition_csv(root/'partitions.csv')
    actual={}
    for p in root.rglob('*'):
        if p.is_symlink():reject('symlink in staged package: '+str(p))
        if p.is_file():
            rel=p.relative_to(root).as_posix()
            if rel!='partitions.csv' and rel.endswith('/partitions.csv'):reject('partitions.csv must be in sketch root')
            if rel!='SNAPACK_LOCAL_ONLY_WIFI.h' and (rel in ('snapack.ino','partitions.csv') or (rel.startswith('ui/') and p.suffix.lower() in ('.ino','.c','.cpp','.h','.hpp')) or ('/' not in rel and p.suffix.lower() in ('.c','.cpp','.h','.hpp') and rel!='SNAPACK_LOCAL_ONLY_WIFI.example.h')):
                actual[rel]=digest(p)
    if set(src)-set(actual) or (not allow_extra and set(actual)-set(src)):reject('source inventory differs; missing='+repr(sorted(set(src)-set(actual)))+' undeclared='+repr(sorted(set(actual)-set(src))))
    for p,h in src.items():
        if actual[p]!=h:reject('source hash mismatch: '+p)
    sketch=(root/'snapack.ino').read_text(errors='replace')
    identities=re.findall(r'^\s*#define\s+SNAPACK_FW_STEP\s+"([^"]+)"\s*$',sketch,re.M)
    if identities!=[info['RELEASE']]:reject('firmware identity mismatch or not unique')
    # Change inventories, behavioral rules and release READMEs are informational.
    # Source integrity, safe paths, partition layout and compilation remain gates.
    print(f"PASS {info['RELEASE']}: {len(src)} source hashes verified; partition layout verified")
    return info,src

def zip_extract(zippath,target):
    with zipfile.ZipFile(zippath) as z:
        names=set()
        for member in z.infolist():
            name=member.filename.rstrip('/')
            safe(name)
            if name in names:reject('duplicate ZIP path: '+name)
            names.add(name)
            if name!='partitions.csv' and name.endswith('/partitions.csv'):reject('partitions.csv must be in sketch root')
            if not (name in ('snapack.ino','partitions.csv','SNAPACK_LOCAL_ONLY_WIFI.example.h','ui','validation','archive','assets') or name.startswith(('ui/','validation/','archive/','assets/')) or ('/' not in name and re.fullmatch(r'[^/]+\.(?:h|c|cpp|hpp)',name))):reject('unexpected ZIP entry: '+name)
            if name.startswith('validation/') and name.endswith(('.sh','.py')):reject('executable validator script not allowed: '+name)
            if (member.external_attr >> 16)&0o170000 == stat.S_IFLNK:reject('ZIP symlink: '+name)
            if member.flag_bits&1:reject('encrypted ZIP entry: '+name)
            dest=target/name
            if member.is_dir():dest.mkdir(parents=True,exist_ok=True);continue
            dest.parent.mkdir(parents=True,exist_ok=True)
            with z.open(member) as src,dest.open('xb') as out:shutil.copyfileobj(src,out)

def managed_inventory(sketch,ui):
    result={}
    for base,prefix in ((sketch,''),(ui,'ui/')):
        iterator=base.iterdir() if not prefix else base.rglob('*')
        for p in iterator:
            if p.is_symlink():reject('symlink in managed source: '+str(p))
            if not p.is_file() or not (p.suffix.lower() in ('.ino','.h','.c','.cpp','.hpp') or (not prefix and p.name=='partitions.csv')):continue
            rel=prefix+p.relative_to(base).as_posix()
            if p.name in ('SNAPACK_LOCAL_ONLY_WIFI.h','SNAPACK_LOCAL_ONLY_WIFI.example.h'):continue
            result[rel]=p
    return result

def backup_hashes(backup):
    records={}
    for p in backup.rglob('*'):
        if p.is_symlink():reject('symlink in source backup: '+str(p))
        if p.is_file() and p.name not in ('BACKUP_SHA256SUMS.txt','INSTALL_STATE.txt','TRANSACTION_REPORT.txt'):
            records[p.relative_to(backup).as_posix()]=digest(p)
    (backup/'BACKUP_SHA256SUMS.txt').write_text(''.join(h+'  '+rel+'\n' for rel,h in sorted(records.items())))
    return records

def verify_backup(backup):
    records={}
    for line in (backup/'BACKUP_SHA256SUMS.txt').read_text().splitlines():
        m=re.fullmatch(r'([0-9a-f]{64})  (.+)',line)
        if not m:reject('invalid backup hash manifest')
        records[m[2]]=m[1]
    for rel,h in records.items():
        p=backup/rel
        if not p.is_file() or p.is_symlink() or digest(p)!=h:reject('source backup hash verification failed: '+rel)
    return records

def restore_backup(sketch,ui,backup,installed):
    verify_backup(backup)
    # Preserve all current managed source before restoration, including failed additions.
    failed=sketch/'recovery/failed_sources'/backup.name
    if failed.exists():reject('failed-source preservation path already exists: '+str(failed))
    failed.mkdir(parents=True)
    for rel,p in managed_inventory(sketch,ui).items():
        dest=failed/rel;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(p,dest)
    for name in ('validation','archive','assets'):
        if (sketch/name).is_dir():shutil.copytree(sketch/name,failed/name)
    current=managed_inventory(sketch,ui)
    for p in current.values():p.unlink()
    for rel in installed:
        origin=backup/rel
        dest=(ui/rel[3:]) if rel.startswith('ui/') else (sketch/rel)
        dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(origin,dest)
    for name in ('validation','archive','assets'):
        dest=sketch/name
        if dest.exists():shutil.rmtree(dest)
        if (backup/name).exists():shutil.copytree(backup/name,dest)
    for rel in installed:
        dest=(ui/rel[3:]) if rel.startswith('ui/') else (sketch/rel)
        if digest(dest)!=digest(backup/rel):reject('restoration hash mismatch: '+rel)
    wifi=sketch/'SNAPACK_LOCAL_ONLY_WIFI.h'
    if digest(wifi)!=digest(backup/'SNAPACK_LOCAL_ONLY_WIFI.h'):reject('Wi-Fi header restoration verification failed')
    print('RESTORED previous source; failed candidate preserved:',failed,flush=True)
    return failed

def check_local_includes(root,src):
    # Quoted includes must resolve in candidate, or in explicitly approved installed libraries.
    # External UI library is represented by the candidate's ui/ tree.
    for rel in sorted(src):
        p=root/rel
        try: text=p.read_text(errors='replace')
        except OSError as e:reject('cannot inspect includes: '+rel+': '+str(e))
        for header in re.findall(r'^\s*#\s*include\s*"([^"\n]+)"',text,re.M):
            if header == "SNAPACK_LOCAL_ONLY_WIFI.h":continue
            safe(header)
            options=[p.parent/header,root/header,root/'ui'/header]
            if any(x.is_file() and not x.is_symlink() for x in options):continue
            if header in ('ui_helpers.h','ui_events.h','ui_helpers.c','ui_events.c'):
                reject('required SquareLine UI support missing from release: '+rel+' -> '+header)
            # Arduino installed libraries are resolved by the compiler; do not
            # falsely reject their headers here. Report unresolved includes for diagnosis.
            print('INCLUDE NEEDS COMPILER RESOLUTION:',rel,'->',header,flush=True)

def install(zipfile_path,sketch_path,ui_path):
    sketch=Path(sketch_path);ui=Path(ui_path);zippath=Path(zipfile_path)
    if not zippath.is_file():reject('ZIP not found')
    if not sketch.is_dir() or not ui.is_dir():reject('working sketch or external UI library missing')
    wifi=sketch/'SNAPACK_LOCAL_ONLY_WIFI.h'
    if not wifi.is_file() or wifi.is_symlink():reject('local Wi-Fi header missing or unsafe; installation refused')
    wifi_hash=digest(wifi)
    recovery=sketch/'recovery';recovery.mkdir(exist_ok=True)
    backups=recovery/'source_backups';backups.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='snapflash-zip-') as tmp:
        root=Path(tmp)/'package';root.mkdir();zip_extract(zippath,root)
        info,src=validate(root)
        current=managed_inventory(sketch,ui)
        stamp=time.strftime('%Y%m%d-%H%M%S')+'-'+str(os.getpid());backup=backups/stamp
        backup.mkdir()
        report=backup/'TRANSACTION_REPORT.txt'
        def note(message):
            print(message,flush=True)
            with report.open('a') as f:f.write(message+'\n')
        note('Release: '+info['RELEASE'])
        note('Source backup: '+str(backup))
        note('Original ZIP: '+str(zippath))
        note('Package validation: PASS')
        for rel,p in sorted(current.items()):
            dest=backup/rel;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(p,dest)
        for name in ('validation','archive','assets'):
            if (sketch/name).exists():shutil.copytree(sketch/name,backup/name,symlinks=False)
        shutil.copy2(wifi,backup/'SNAPACK_LOCAL_ONLY_WIFI.h')
        note('Protected local Wi-Fi header: preserved')
        backup_hashes(backup);verify_backup(backup)
        staged=backup/'candidate';shutil.copytree(root,staged)
        for rel,p in current.items():
            if rel not in src:
                dest=staged/rel;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(p,dest)
        shutil.copy2(wifi,staged/'SNAPACK_LOCAL_ONLY_WIFI.h')
        if digest(staged/'SNAPACK_LOCAL_ONLY_WIFI.h')!=wifi_hash:reject('Wi-Fi preservation check failed')
        validate(root);check_local_includes(staged,dict.fromkeys(set(src)|set(current)))
        note('Candidate location: '+str(staged))
        note('Staged validation: PASS')
        note('Backup hash verification: PASS')
        journal=backup/'INSTALL_STATE.txt';journal.write_text('INSTALLING\n')
        try:
            for rel in sorted(src):
                target=(ui/rel[3:]) if rel.startswith('ui/') else (sketch/rel)
                target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(root/rel,target)
            for name in ('validation','archive','assets'):
                dest=sketch/name
                if dest.exists():shutil.rmtree(dest)
                if (root/name).is_dir():
                    if name=='archive' and (backup/'archive').is_dir():
                        shutil.copytree(backup/'archive',dest)
                        shutil.copytree(root/name,dest,dirs_exist_ok=True)
                    else:shutil.copytree(root/name,dest)
            if digest(wifi)!=wifi_hash:reject('local Wi-Fi header changed during installation')
            check=Path(tmp)/'installed';check.mkdir();shutil.copytree(sketch/'validation',check/'validation')
            for rel in src:
                dest=check/rel;dest.parent.mkdir(parents=True,exist_ok=True)
                shutil.copy2((ui/rel[3:]) if rel.startswith('ui/') else (sketch/rel),dest)
            if (sketch/'assets').is_dir():shutil.copytree(sketch/'assets',check/'assets')
            validate(check)
            for rel in set(current)-set(src):
                installed_path=(ui/rel[3:]) if rel.startswith('ui/') else (sketch/rel)
                if not installed_path.is_file() or digest(installed_path)!=digest(current[rel]):reject('existing source unexpectedly changed: '+rel)
            journal.write_text('INSTALLED '+info['RELEASE']+'\n')
            note('Installed validation: PASS')
            note('Automatic flashing: NONE')
        except Exception:
            note('Installation failed; automatic restoration requested')
            restore_backup(sketch,ui,backup,current)
            journal.write_text('ROLLED_BACK\n')
            note('Restoration: VERIFIED')
            note('Automatic flashing: NONE')
            raise
        note('INSTALLED '+info['RELEASE']+'; awaiting compilation')

def restore_latest(sketch_path,ui_path):
    sketch=Path(sketch_path);ui=Path(ui_path);backups=sketch/'recovery/source_backups'
    choices=sorted((p for p in backups.iterdir() if p.is_dir() and (p/'INSTALL_STATE.txt').is_file() and (p/'INSTALL_STATE.txt').read_text().startswith('INSTALLED')),reverse=True)
    if not choices:reject('no installed source backup available for restoration')
    backup=choices[0];verify_backup(backup)
    installed={}
    for p in backup.rglob('*'):
        if not p.is_file() or 'quarantine' in p.parts or 'candidate' in p.parts:continue
        rel=p.relative_to(backup).as_posix()
        if rel in ('snapack.ino','partitions.csv') or (rel.startswith('ui/') and p.suffix.lower() in ('.ino','.h','.c','.cpp','.hpp')) or ('/' not in rel and p.suffix.lower() in ('.ino','.h','.c','.cpp','.hpp') and p.name!='SNAPACK_LOCAL_ONLY_WIFI.h'):
            installed[rel]=p
    restore_backup(sketch,ui,backup,installed)
    (backup/'INSTALL_STATE.txt').write_text('RESTORED\n')

try:
    if sys.argv[1]=='validate':validate(Path(sys.argv[2]))
    elif sys.argv[1]=='validate-installed':validate(Path(sys.argv[2]),allow_extra=True)
    elif sys.argv[1]=='install':install(*sys.argv[2:5])
    elif sys.argv[1]=='restore':restore_latest(*sys.argv[2:4])
    elif sys.argv[1]=='partition-csv':partition_csv(Path(sys.argv[2]));print('PASS: SNAPACK partitions.csv layout')
    elif sys.argv[1]=='partition-bin':partition_bin(Path(sys.argv[2]),len(sys.argv)>3 and sys.argv[3]=='assets')
    elif sys.argv[1]=='assets':verify_assets(Path(sys.argv[2]))
    elif sys.argv[1]=='assets-legacy-archive':verify_assets(Path(sys.argv[2]),legacy_archive=True)
    else:reject('unknown contract engine mode')
except (ValueError,OSError,zipfile.BadZipFile,UnicodeError) as e:
    print('SNAPFLASH VALIDATION/INSTALLATION FAILED:',e,file=sys.stderr);sys.exit(1)
SNAPFLASH_CONTRACT_PY
}

# =========================================================================================
# MARKER: FROZEN CLI BUILD / SOURCE PREFLIGHT (NEW IN 1.2.0)
# =========================================================================================
# CLI extracted from the Gear Lever managed AppImage at runtime. No mount, install, download, or package updates.
# A failed build never falls through to stale IDE binaries.
source_preflight() {
    local sketch="$SKETCH_DIR/snapack.ino" count step_line
    local validation_dir="$SKETCH_DIR/validation"
    [[ -f "$sketch" ]] || { print_error "Missing sketch: $sketch"; return 1; }
    [[ -f "$SKETCH_DIR/partitions.csv" && ! -L "$SKETCH_DIR/partitions.csv" ]] || { print_error "Required sketch-root partitions.csv missing or unsafe; FLASH REFUSED."; return 1; }
    if [[ -f "$SKETCH_DIR/validation/RELEASE_INFO.txt" ]] && [[ -d "$SKETCH_DIR/assets" ]]; then
        snapflash_contract assets "$SKETCH_DIR" || return 1
    fi
    snapflash_contract partition-csv "$SKETCH_DIR/partitions.csv" || return 1
    [[ -f "$UI_LIB_DIR/ui.h" ]] || { print_error "UI library missing or incomplete: $UI_LIB_DIR"; return 1; }
    # Require exactly one active firmware step declaration; comments do not count.
    count=$(grep -Ec '^[[:space:]]*#define[[:space:]]+SNAPACK_FW_STEP[[:space:]]+' "$sketch" || true)
    [[ "$count" == 1 ]] || { print_error "Expected one SNAPACK_FW_STEP definition; found $count."; return 1; }
    # Contract v1: permanent internal validator. Legacy releases retain their historical path.
    if [[ -f "$validation_dir/RELEASE_INFO.txt" ]]; then
        local contract_view
        contract_view=$(mktemp -d /tmp/snapflash-contract-view.XXXXXX) || return 1
        if ! cp -a -- "$validation_dir" "$contract_view/validation" ||
           ! cp -- "$sketch" "$contract_view/snapack.ino" ||
           ! cp -- "$SKETCH_DIR/partitions.csv" "$contract_view/partitions.csv" ||
           ! cp -a -- "$UI_LIB_DIR" "$contract_view/ui"; then
            rm -rf -- "$contract_view"; print_error "Cannot prepare contract validation view"; return 1
        fi
        if [[ -d "$SKETCH_DIR/assets" ]]; then cp -a -- "$SKETCH_DIR/assets" "$contract_view/assets" || { rm -rf -- "$contract_view"; return 1; }; fi
        local source_file
        for source_file in "$SKETCH_DIR"/*.h "$SKETCH_DIR"/*.c "$SKETCH_DIR"/*.cpp "$SKETCH_DIR"/*.hpp; do
            [[ -f "$source_file" ]] || continue
            [[ "$(basename "$source_file")" == SNAPACK_LOCAL_ONLY_WIFI.h || "$(basename "$source_file")" == SNAPACK_LOCAL_ONLY_WIFI.example.h ]] && continue
            cp -- "$source_file" "$contract_view/$(basename "$source_file")" || { rm -rf -- "$contract_view"; return 1; }
        done
        VALIDATION_LOG=$(mktemp /tmp/snapflash-validation.XXXXXX) || { rm -rf -- "$contract_view"; return 1; }
        if ! snapflash_contract validate-installed "$contract_view" > "$VALIDATION_LOG" 2>&1; then
            cat "$VALIDATION_LOG"; rm -rf -- "$contract_view"
            print_error "Integrated contract validation failed; FLASH REFUSED. Report: $VALIDATION_LOG"
            return 1
        fi
        RELEASE_STEP=$(sed -n 's/^RELEASE=//p' "$validation_dir/RELEASE_INFO.txt")
        cat "$VALIDATION_LOG"; rm -rf -- "$contract_view"
        return 0
    fi
    # Legacy package: no producer-specific behavioral validator is executed.
    # Compilation remains the authoritative implementation check.
    RELEASE_STEP=$(sed -n 's/^[[:space:]]*#define[[:space:]]*SNAPACK_FW_STEP[[:space:]]*"\(STEP[[:alnum:]_]*\)".*/\1/p' "$sketch" | head -n 1)
    VALIDATION_LOG=$(mktemp /tmp/snapflash-validation.XXXXXX) || return 1
    printf 'PASS: legacy source preflight; behavior rules deferred to compilation\n' > "$VALIDATION_LOG"
    return 0
}

# Capture source before compilation and compare the same source after compilation.
# This prevents a source archive from silently describing a later edit.
make_source_snapshot() {
    local output="$1"
    tar -czf "$output" -C "$SKETCH_DIR" \
        --exclude='./recovery' --exclude='./build' --exclude='./archive' --exclude='./.git' \
        --exclude='SNAPACK_LOCAL_ONLY_WIFI.h' \
        --exclude='*/SNAPACK_LOCAL_ONLY_WIFI.h' \
        -C "$SKETCH_DIR" . \
        -C "$(dirname "$UI_LIB_DIR")" "$(basename "$UI_LIB_DIR")"
}

# Content inventory deliberately ignores directory metadata and tar/gzip metadata.
# It detects added, removed, and modified source files in both source trees.
make_source_inventory() {
    local output="$1" root prefix file relative digest
    : > "$output" || return 1
    for prefix in sketch ui; do
        if [[ "$prefix" == sketch ]]; then root="$SKETCH_DIR"; else root="$UI_LIB_DIR"; fi
        [[ -d "$root" && ! -L "$root" ]] || return 1
        while IFS= read -r -d '' file; do
            relative="${file#"$root"/}"
            if [[ -L "$file" ]]; then
                digest="LINK:$(readlink -- "$file")" || return 1
            elif [[ -f "$file" ]]; then
                digest=$(sha256sum -- "$file") || return 1
                digest="${digest%% *}"
            else
                digest="OTHER"
            fi
            printf '%s\t%s/%s\n' "$digest" "$prefix" "$relative" >> "$output" || return 1
        done < <(find "$root" \
            \( -name recovery -o -name build -o -name archive -o -name .git \) -type d -prune -o \
            ! -type d ! -name SNAPACK_LOCAL_ONLY_WIFI.h -print0 | LC_ALL=C sort -z)
    done
}

# Persist both the compiler output and a failure-specific report beside the incoming ZIP.
retain_build_failure() {
    local reason="$1" detail="${2:-}" local_log report stem
    [[ "${ZIP_INSTALL_MODE:-0}" == 1 && -d "${RELEASE_ZIP_NEW:-}" && ! -L "${RELEASE_ZIP_NEW:-}" ]] || return 0
    stem="${RELEASE_STEP:-SNAPACK}_failed_$(date +%Y%m%d_%H%M%S)_$$"
    local_log="$RELEASE_ZIP_NEW/${stem}_compile.log"
    report="$RELEASE_ZIP_NEW/${stem}_failure.txt"
    if [[ -f "${STAGED_BUILD:-}/compile.log" ]]; then
        cp -- "$STAGED_BUILD/compile.log" "$local_log" || print_error "Could not retain compiler log: $local_log"
    fi
    {
        printf 'Failure: %s\n' "$reason"
        printf 'Release: %s\nBuild directory: %s\n' "${RELEASE_STEP:-unknown}" "${STAGED_BUILD:-unknown}"
        [[ -z "$detail" ]] || printf '%s\n' "$detail"
        printf 'No flash attempted by the compilation stage.\n'
    } > "$report" || { print_error "Could not retain failure report: $report"; return 1; }
    print_warn "LOCAL FAILURE REPORT: $report"
    [[ ! -f "$local_log" ]] || print_warn "LOCAL COMPILE LOG: $local_log"
}

wifi_header_hash() {
    local header="$SKETCH_DIR/SNAPACK_LOCAL_ONLY_WIFI.h"
    if [[ -f "$header" ]]; then
        sha256sum "$header" | awk '{print $1}'
    else
        printf '%s\n' ABSENT
    fi
}

# Extract the CLI from the operator's existing AppImage into a private temporary
# directory. No mount survives a terminal close; no toolchain is installed or updated.
cleanup_appimage_extraction() {
    if [[ -n "${APPIMAGE_EXTRACT_DIR:-}" && -d "$APPIMAGE_EXTRACT_DIR" && ! -L "$APPIMAGE_EXTRACT_DIR" ]]; then
        rm -rf -- "$APPIMAGE_EXTRACT_DIR"
    fi
    APPIMAGE_EXTRACT_DIR=""
}
trap cleanup_appimage_extraction EXIT

prepare_frozen_cli() {
    [[ -f "$ARDUINO_APPIMAGE" && -x "$ARDUINO_APPIMAGE" && ! -L "$ARDUINO_APPIMAGE" ]] || {
        print_error "Existing Gear Lever Arduino AppImage unavailable or not executable: $ARDUINO_APPIMAGE"
        return 1
    }
    if [[ -n "$CLI" && -x "$CLI" ]]; then return 0; fi
    APPIMAGE_EXTRACT_DIR=$(mktemp -d /tmp/snapflash-appimage.XXXXXXXX) || return 1
    print_info "Extracting CLI from existing Arduino AppImage (temporary; no install or mount)."
    if ! (cd "$APPIMAGE_EXTRACT_DIR" && "$ARDUINO_APPIMAGE" --appimage-extract > extraction.log 2>&1); then
        print_error "Existing Arduino AppImage extraction failed. No alternate CLI will be used."
        tail -n 12 "$APPIMAGE_EXTRACT_DIR/extraction.log" 2>/dev/null || true
        return 1
    fi
    CLI="$APPIMAGE_EXTRACT_DIR/squashfs-root/resources/app/lib/backend/resources/arduino-cli"
    [[ -f "$CLI" && -x "$CLI" && ! -L "$CLI" ]] || {
        print_error "Bundled Arduino CLI missing from extracted AppImage: $CLI"
        return 1
    }
    if ! "$CLI" version > "$APPIMAGE_EXTRACT_DIR/cli_version.log" 2>&1; then
        print_error "Bundled Arduino CLI failed its version check. FLASH REFUSED."
        return 1
    fi
    print_good "Existing AppImage CLI verified: $(head -n 1 "$APPIMAGE_EXTRACT_DIR/cli_version.log")"
}

compile_isolated_build() {
    local result
    prepare_frozen_cli || return 1
    source_preflight || return 1
    STAGED_BUILD=$(mktemp -d /tmp/snapflash-build.XXXXXX) || return 1
    STAGED_SOURCE="$STAGED_BUILD/source_before.tar.gz"
    make_source_snapshot "$STAGED_SOURCE" || {
        print_error "Could not snapshot source before compilation; FLASH REFUSED."
        retain_build_failure "Pre-compilation source snapshot failed"
        return 1
    }
    STAGED_WIFI_HASH=$(wifi_header_hash) || return 1
    STAGED_PARTITION_HASH=$(sha256sum "$SKETCH_DIR/partitions.csv" | awk '{print $1}') || return 1
    if [[ -d "$SKETCH_DIR/assets" ]]; then snapflash_contract assets "$SKETCH_DIR" || return 1; fi
    if [[ -f "$SKETCH_DIR/validation/SOURCE_MANIFEST_SHA256.txt" ]]; then
        local expected_partition_hash
        expected_partition_hash=$(awk '$2=="partitions.csv" {print $1}' "$SKETCH_DIR/validation/SOURCE_MANIFEST_SHA256.txt")
        [[ "$STAGED_PARTITION_HASH" == "$expected_partition_hash" ]] || { print_error "Partition hash differs from release manifest; FLASH REFUSED."; return 1; }
    fi
    if ! make_source_inventory "$STAGED_BUILD/inventory_before.txt"; then
        print_error "Could not inventory source before compilation; FLASH REFUSED."
        retain_build_failure "Pre-compilation source inventory failed"
        return 1
    fi
    print_info "Isolated Build: $STAGED_BUILD"
    print_info "Using Verified IDE Board Configuration."
    print_info "COMPILATION STARTING -- output is saved to compile.log; this may take several minutes."
    if "$CLI" compile --fqbn "$FQBN" --build-path "$STAGED_BUILD" --warnings none "$SKETCH_DIR" > "$STAGED_BUILD/compile.log" 2>&1; then
        print_good "COMPILATION SUCCEEDED -- checking source consistency and build artifacts."
        tail -n 12 "$STAGED_BUILD/compile.log"
    else
        result=$?
        print_error "Compilation failed (exit $result); FLASH REFUSED."
        tail -n 35 "$STAGED_BUILD/compile.log"
        print_warn "Build log retained at $STAGED_BUILD/compile.log"
        retain_build_failure "Compiler returned exit status $result"
        return 1
    fi
    # Verify The Authoritative Partition Input After Compilation.
    local partition_after
    partition_after=$(sha256sum "$SKETCH_DIR/partitions.csv" | awk '{print $1}') || return 1
    if [[ "$partition_after" != "$STAGED_PARTITION_HASH" ]]; then
        print_error "Sketch-root partitions.csv changed during compilation; FLASH REFUSED."
        retain_build_failure "Partition input changed during compilation"
        return 1
    fi
    # Compare content inventories, not compressed tar bytes: directory timestamps and
    # archive metadata can differ without any source file changing.
    if ! make_source_inventory "$STAGED_BUILD/inventory_after.txt"; then
        print_error "Could not inventory source after compilation; FLASH REFUSED."
        retain_build_failure "Post-compilation source inventory failed"
        return 1
    fi
    if ! cmp -s "$STAGED_BUILD/inventory_before.txt" "$STAGED_BUILD/inventory_after.txt"; then
        print_error "Source files changed during compilation; FLASH REFUSED."
        local differences
        differences=$(diff -u -- "$STAGED_BUILD/inventory_before.txt" "$STAGED_BUILD/inventory_after.txt" || true)
        printf '%s\n' "$differences"
        retain_build_failure "Source content inventory mismatch" "$differences"
        return 1
    fi
    local wifi_after
    wifi_after=$(wifi_header_hash) || {
        retain_build_failure "Could not hash local Wi-Fi configuration after compilation"
        return 1
    }
    if [[ "$STAGED_WIFI_HASH" != "$wifi_after" ]]; then
        print_error "Local Wi-Fi configuration changed during compilation; FLASH REFUSED."
        retain_build_failure "Local Wi-Fi header hash mismatch" "Before: $STAGED_WIFI_HASH; after: $wifi_after"
        return 1
    fi
    # Keep the original source archive for provenance; inventory is authoritative
    # for content consistency, avoiding false failures from tar metadata changes.
    if ! make_source_snapshot "$STAGED_BUILD/source_after.tar.gz"; then
        print_error "Could not snapshot source after compilation; FLASH REFUSED."
        retain_build_failure "Post-compilation source snapshot failed"
        return 1
    fi
    local name
    for name in snapack.ino.bin snapack.ino.bootloader.bin snapack.ino.partitions.bin; do
        [[ -s "$STAGED_BUILD/$name" ]] || {
            print_error "Fresh build artifact missing/empty: $name; FLASH REFUSED."
            retain_build_failure "Missing or empty build artifact: $name"
            return 1
        }
    done
    if ! snapflash_contract partition-bin "$STAGED_BUILD/snapack.ino.partitions.bin" "$([[ -d "$SKETCH_DIR/assets" ]] && echo assets)"; then
        print_error "Generated Partition Binary Does Not Match Sketch-Root CSV; FLASH REFUSED."
        retain_build_failure "Generated partition binary mismatch"
        return 1
    fi
    local app_size
    app_size=$(stat -c %s "$STAGED_BUILD/snapack.ino.bin") || return 1
    if (( app_size > $([[ -d "$SKETCH_DIR/assets" ]] && echo 0x9F0000 || echo 0xFF0000) )); then
        print_error "Application BIN Exceeds Its Release Partition; FLASH REFUSED."
        retain_build_failure "Application BIN exceeds partition size"
        return 1
    fi
    print_good "Build checks passed. Compilation stage complete."
    BUILD_DIR="$STAGED_BUILD"
    BUILD_ORIGIN="Gear Lever AppImage CLI (isolated build)"
    return 0
}

# Store source and build provenance in addition to the existing four-BIN recovery unit.
# Source snapshot is created only for new CLI builds, not historical restore operations.
archive_build_provenance() {
    local dest="$1"
    [[ "$BUILD_ORIGIN" == "Gear Lever AppImage CLI (isolated build)" ]] || return 0
    [[ -f "$BUILD_DIR/compile.log" ]] || return 1
    [[ -f "$SKETCH_DIR/partitions.csv" && ! -L "$SKETCH_DIR/partitions.csv" ]] || return 1
    cp -- "$BUILD_DIR/compile.log" "$dest/compile.log" || return 1
    [[ -s "$VALIDATION_LOG" ]] || return 1
    cp -- "$VALIDATION_LOG" "$dest/SOURCE_VALIDATION.txt" || return 1
    # Preserve the exact snapshot captured BEFORE compilation, not a later source state.
    [[ -s "$STAGED_SOURCE" ]] || return 1
    cp -- "$STAGED_SOURCE" "$dest/source_snapshot.tar.gz" || return 1
    cmp -s "$STAGED_SOURCE" "$dest/source_snapshot.tar.gz" || return 1
    {
        echo "Build origin: $BUILD_ORIGIN"
        echo "AppImage: $ARDUINO_APPIMAGE"
        echo "CLI: bundled resources/app/lib/backend/resources/arduino-cli (temporarily extracted)"
        "$CLI" version
        echo "FQBN: $FQBN"
        echo "Sketch-root partitions.csv SHA-256: $STAGED_PARTITION_HASH"
        echo "Generated partition BIN verified against SNAPACK 16 MiB layout."
        echo "Source: $SKETCH_DIR"
        echo "Local Wi-Fi header SHA-256 (header excluded): $STAGED_WIFI_HASH"
        echo "Source snapshot captured before compilation; source content inventory checked afterward."
        echo "Staging: $BUILD_DIR"
        echo "Source snapshot includes validation/; excludes recovery, build, archive, .git and local-only Wi-Fi header."
    } > "$dest/BUILD_PROVENANCE.txt" || return 1
    (cd "$dest" && sha256sum compile.log source_snapshot.tar.gz BUILD_PROVENANCE.txt SOURCE_VALIDATION.txt > SOURCE_SHA256SUMS && sha256sum -c SOURCE_SHA256SUMS >/dev/null) || return 1
}

# A disconnected controller is not a failed build. Keep the verified archive and
# allow repeated probes without invoking compilation again.
wait_for_controller_after_build() {
    local answer
    while true; do
        if controller_trust_gate; then return 0; fi
        echo
        print_warn "The verified firmware archive remains available; no recompilation is needed."
        echo -ne "Connect the controller, then [R]etry or [0] return to menu: "
        read -r answer || return 1
        case "$answer" in
            [Rr]|"") continue ;;
            0|[Qq]) return 1 ;;
            *) print_warn "Choose R or 0." ;;
        esac
    done
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
print_header "SNAPACK FIRMWARE UTILITY - VERSION 1.2.28"

# Read firmware identity for display only; source_preflight remains authoritative.
MENU_RELEASE="UNKNOWN"
if [[ -f "$SKETCH_DIR/snapack.ino" ]]; then
    MENU_IDENTITY=$(grep -E '^[[:space:]]*#define[[:space:]]+SNAPACK_FW_STEP[[:space:]]+' "$SKETCH_DIR/snapack.ino" || true)
    MENU_PATTERN='^[[:space:]]*#define[[:space:]]+SNAPACK_FW_STEP[[:space:]]+"(STEP[[:alnum:]_]+)"[[:space:]]*$'
    if [[ $(printf '%s\n' "$MENU_IDENTITY" | grep -c . || true) == 1 && "$MENU_IDENTITY" =~ $MENU_PATTERN ]]; then
        MENU_RELEASE="${BASH_REMATCH[1]}"
    fi
fi
echo
echo
echo -e "${YELLOW}     1) Compile, Archive And Flash Current SketchRoot ${NC} ${GREEN}(${MENU_RELEASE})${NC}"
echo -e "${YELLOW}     2) Restore Archived Firmware${NC}"
echo -e "${YELLOW}     3) Archive And Flash Existing Binary Files${NC}"
echo -e "${YELLOW}     4) Recovery And Archive Tools ->${NC}"
echo -e "${YELLOW}     5) Exit${NC}"
echo -e "${YELLOW}     6) Resume Verified Build (NO RECOMPILE)${NC}"
echo -e "${YELLOW}     8) Install Release ZIP, Compile And Archive (NO FLASH)${NC}"
echo
echo -e "${CYAN} = = > Build Source:${NC}   ${GREEN}$BUILD_DIR${NC}"
echo -e "${CYAN} = = > Archive Root:${NC}   ${GREEN}$ARCHIVE_DIR${NC}"
echo -e "${CYAN} = = > Image Root:${NC}     ${GREEN}$IMAGE_ARCHIVE_DIR${NC}"
echo -e "${CYAN} = = > Trust Registry:${NC} ${GREEN}$TRUSTED_DEVICES_FILE${NC}"
echo -e "${CYAN} = = > Flash Device:${NC}   ${GREEN}$PORT${NC}"
echo

echo -ne "${YELLOW} = = > Select Mission [1-6,8]: ${NC}${GREEN}"
read -r CHOICE
echo -ne "${NC}"

# Main-menu routing preserves the original, tested operation handlers.
# The submenu exposes original choices 3, 4, and 7 without duplicating their logic.
if [[ "$CHOICE" == "3" ]]; then
    CHOICE="9"
elif [[ "$CHOICE" == "4" ]]; then
    clear_screen
    print_header "RECOVERY AND ARCHIVE TOOLS"
    echo -e "${YELLOW}     1) Restore Full 16 MB Device Image${NC}"
    echo -e "${YELLOW}     2) Capture Full 16 MB Device Image${NC}"
    echo -e "${YELLOW}     3) Validate And Archive Existing Binary Files (NO FLASH)${NC}"
    echo -e "${YELLOW}     0) Return To Main Menu${NC}"
    echo
    echo -ne "${YELLOW} = = > Select Tool [0-3]: ${NC}${GREEN}"
    read -r TOOL_CHOICE
    echo -ne "${NC}"
    case "$TOOL_CHOICE" in
        0) continue ;;
        1) CHOICE="3" ;;
        2) CHOICE="4" ;;
        3) CHOICE="7" ;;
        *) print_error "Invalid Tool Selection: $TOOL_CHOICE"; pause_screen; continue ;;
    esac
fi

# Compile before entering the existing archive/flash path. A failed compilation cannot
# accidentally flash old IDE exports. Internal choice 9 is the IDE-export path;
# main-menu option 6 must pass untouched to the resume-only case handler.
ZIP_INSTALL_MODE=0
BUILD_DIR="$IDE_BUILD_DIR"
BUILD_ORIGIN="Arduino IDE export"
ARCHIVE_ONLY=0
if [[ "$CHOICE" == "7" ]]; then ARCHIVE_ONLY=1; CHOICE="9"; fi
if [[ "$CHOICE" == "8" ]]; then
    clear_screen
    print_header "INSTALL RELEASE ZIP (NO FLASH)"
    # Incoming queue is deliberate: never infer the intended release from timestamps.
    RELEASE_ZIP_ARCHIVE="$SKETCH_DIR/recovery/Firm_Ware/Current_Working_Firmware/Archive"
    RELEASE_ZIP_NEW="$RELEASE_ZIP_ARCHIVE/New"
    if [[ ! -d "$RELEASE_ZIP_NEW" || -L "$RELEASE_ZIP_NEW" ]]; then
        print_error "Incoming ZIP directory missing or unsafe: $RELEASE_ZIP_NEW"
        pause_screen; continue
    fi
    RELEASE_ZIPS=()
    while IFS= read -r -d '' ZIP_CANDIDATE; do
        RELEASE_ZIPS+=("$ZIP_CANDIDATE")
    done < <(find "$RELEASE_ZIP_NEW" -mindepth 1 -maxdepth 1 -type f -iname '*.zip' -print0)
    if (( ${#RELEASE_ZIPS[@]} == 0 )); then
        print_warn "No release ZIP found in New. Place one ZIP there and retry."
        pause_screen; continue
    elif (( ${#RELEASE_ZIPS[@]} != 1 )); then
        print_error "Found ${#RELEASE_ZIPS[@]} ZIP files in New; refusing to guess. Leave exactly one:"
        printf '  %s\n' "${RELEASE_ZIPS[@]##*/}"
        pause_screen; continue
    fi
    RELEASE_ZIP="${RELEASE_ZIPS[0]}"
    RELEASE_ZIP_NAME="${RELEASE_ZIP##*/}"
    RELEASE_ZIP_DEST="$RELEASE_ZIP_ARCHIVE/$RELEASE_ZIP_NAME"
    if [[ -e "$RELEASE_ZIP_DEST" || -L "$RELEASE_ZIP_DEST" ]]; then
        print_error "Archive already contains $RELEASE_ZIP_NAME; will not overwrite it."
        pause_screen; continue
    fi
    print_info "Incoming Release ZIP: $RELEASE_ZIP_NAME"
    print_warn "This operation replaces the managed sketch and external UI source after creating a source backup."
    print_warn "Compilation and BIN archival follow; no controller access or flashing will occur."
    print_info "Option 8 selected: proceeding with validated ZIP installation (no flash)."
    pause_screen "Press Enter To Install This Release, Or Ctrl+C To Cancel..."
    if ! snapflash_contract install "$RELEASE_ZIP" "$SKETCH_DIR" "$UI_LIB_DIR"; then
        print_error "Installation failed; no compilation or flash attempted."
        pause_screen; continue
    fi
    ARCHIVE_ONLY=1
    ZIP_INSTALL_MODE=1
    CHOICE="1"
fi
STAGED_BUILD=""
STAGED_SOURCE=""
STAGED_WIFI_HASH=""
if [[ "$CHOICE" == "1" ]]; then
    clear_screen
    print_header "ISOLATED SNAPACK COMPILATION"
    if ! compile_isolated_build; then
        if [[ "${ZIP_INSTALL_MODE:-0}" == 1 ]]; then
            print_warn "Build workflow failed; restoring preceding sketch and UI sources automatically."
            if snapflash_contract restore "$SKETCH_DIR" "$UI_LIB_DIR"; then
                print_good "Previous source restored; failed source retained for diagnosis. No flash attempted."
            else
                print_error "AUTOMATIC RESTORATION FAILED. Inspect source backup before any further installation."
            fi
        fi
        pause_screen
        continue
    fi
elif [[ "$CHOICE" == "9" ]]; then
    # Existing IDE binaries cannot be cryptographically tied to the current source.
    # Validate source, then ask the operator to confirm the export is current.
    if ! source_preflight; then pause_screen; continue; fi
    print_warn "Source validation cannot prove that existing IDE BINs came from this source."
    print_warn "Confirm the $RELEASE_STEP IDE Export Compiled Binary completed AFTER these source changes."
    echo -ne "IDE export completed after source changes? [Enter=Yes / N=Cancel]: "
    read -r CONFIRM_EXPORT
    case "$CONFIRM_EXPORT" in
        ""|[Yy]) ;;
        [Nn]) print_warn "Cancelled."; pause_screen; continue ;;
        *) print_warn "Enter, Y, or N only. Cancelled."; pause_screen; continue ;;
    esac
    CHOICE="1"
fi

case "$CHOICE" in

# =========================================================================================
# 1) ARCHIVE + FLASH NEW BUILD
# =========================================================================================

1)
    # Archive-only is a file operation: do not require a connected controller,
    # probe a serial port, or change the status of the previous physical flash.
    if (( ARCHIVE_ONLY == 0 )); then
        print_info "Compilation complete. Archiving verified build before controller detection."
    fi

    clear_screen
    if (( ARCHIVE_ONLY == 1 )); then
        print_header "VALIDATE + ARCHIVE IDE EXPORT (NO FLASH)"
    else
        print_header "ARCHIVE + FLASH NEW BUILD"
    fi

    REQUIRED_FILES=(
        "$BUILD_DIR/snapack.ino.bootloader.bin"
        "$BUILD_DIR/snapack.ino.partitions.bin"
        "$BUILD_DIR/snapack.ino.bin"
        "$BOOT_APP0"
    )
    if [[ -d "$SKETCH_DIR/assets" ]]; then
        ARCHIVE_ONLY=1
        REQUIRED_FILES+=("$SKETCH_DIR/assets/snapack_assets.bin" "$SKETCH_DIR/assets/ASSET_MANIFEST_SHA256.txt" "$SKETCH_DIR/partitions.csv")
        snapflash_contract assets "$SKETCH_DIR" || { pause_screen; continue; }
    fi

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

    if ! snapflash_contract partition-bin "$BUILD_DIR/snapack.ino.partitions.bin" "$([[ -d "$SKETCH_DIR/assets" ]] && echo assets)"; then
        print_error "Partition Binary Is Incompatible With Current SNAPACK Layout; Archival Refused."
        pause_screen; continue
    fi
    APP_BIN_SIZE=$(stat -c %s "$BUILD_DIR/snapack.ino.bin") || { pause_screen; continue; }
    if (( APP_BIN_SIZE > $([[ -d "$SKETCH_DIR/assets" ]] && echo 0x9F0000 || echo 0xFF0000) )); then
        print_error "Application BIN Exceeds Its Release Partition; Archival Refused."
        pause_screen; continue
    fi
    clear_screen
    if (( ARCHIVE_ONLY == 1 )); then
        print_header "READY TO ARCHIVE ONLY (NO FLASH)"
    else
        print_header "READY TO ARCHIVE + FLASH"
    fi
    print_info "Proposed Operation:"
    echo -e "${CYAN}       Build Source:${NC} ${GREEN}$BUILD_DIR${NC}"
    echo -e "${CYAN}       Archive Root:${NC} ${GREEN}$ARCHIVE_DIR${NC}"
    if (( ARCHIVE_ONLY == 1 )); then
        echo -e "${CYAN}       Controller:${NC}   ${GREEN}Not required (archive only)${NC}"
    else
        echo -e "${CYAN}       Flash Device:${NC} ${GREEN}$PORT${NC}"
        echo -e "${CYAN}       Chip:${NC}         ${GREEN}ESP32-S3${NC}"
        echo -e "${CYAN}       Controller MAC:${NC} ${GREEN}$CONTROLLER_MAC${NC}"
        echo -e "${CYAN}       Trust Status:${NC}   ${GREEN}$CONTROLLER_TRUST${NC}"
    fi
    echo
    echo -e "${YE} = = > The Current Arduino Build Will Be Archived.${NC}"
    if (( ARCHIVE_ONLY == 1 )); then
        echo -e "${GR} = = > ARCHIVE ONLY: no controller connection or flash write is required.${NC}"
    else
        echo -e "${YE} = = > The Archived Copies Will Then Be Flashed To The Controller.${NC}"
    fi
    echo -e "${YE} = = > No Archive Directory Or Flash Write Has Started Yet.${NC}"
    echo

    # Ask for descriptive metadata BEFORE the final commitment. Keep it only in memory until
    # the operator presses Enter. Ctrl+C at the commitment prompt therefore leaves no archive
    # directory, NOTES.txt, or other debris behind.
    ARCHIVE_NOTE=""
    echo -ne "${YELLOW} = = > Add A Short Description To This Archive? [y/N]: ${NC}${GREEN}"
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
    if (( ARCHIVE_ONLY == 1 )); then
        pause_screen "Press Enter To Validate + Archive WITHOUT FLASHING, Or Ctrl+C To Cancel..."
    else
        pause_screen "Press Enter To Archive + Flash, Or Ctrl+C To Cancel..."
    fi

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
    if [[ -d "$SKETCH_DIR/assets" ]]; then
        mkdir -p "$NEW_ARCHIVE/assets" || { pause_screen; continue; }
        cp -- "$SKETCH_DIR/assets/snapack_assets.bin" "$NEW_ARCHIVE/assets/" || { pause_screen; continue; }
        cp -- "$SKETCH_DIR/assets/ASSET_MANIFEST_SHA256.txt" "$NEW_ARCHIVE/assets/" || { pause_screen; continue; }
        ASSET_LAYOUT_DOCS=("$SKETCH_DIR"/assets/ASSET_LAYOUT_*.txt)
        if [[ ${#ASSET_LAYOUT_DOCS[@]} -ne 1 || ! -f "${ASSET_LAYOUT_DOCS[0]}" ]]; then
            print_error "Expected exactly one asset layout document; FLASH REFUSED."
            pause_screen; continue
        fi
        cp -- "${ASSET_LAYOUT_DOCS[0]}" "$NEW_ARCHIVE/assets/" || { pause_screen; continue; }
        cp -- "$SKETCH_DIR/partitions.csv" "$NEW_ARCHIVE/" || { pause_screen; continue; }
        printf 'SNAPAS1_ASSETS_V1\n' > "$NEW_ARCHIVE/RELEASE_FORMAT" || { pause_screen; continue; }
    fi

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
    if [[ -d "$SKETCH_DIR/assets" ]]; then
        cmp -s "$SKETCH_DIR/assets/snapack_assets.bin" "$NEW_ARCHIVE/assets/snapack_assets.bin" || COPY_CHECK_FAILED=1
        cmp -s "$SKETCH_DIR/assets/ASSET_MANIFEST_SHA256.txt" "$NEW_ARCHIVE/assets/ASSET_MANIFEST_SHA256.txt" || COPY_CHECK_FAILED=1
        cmp -s "${ASSET_LAYOUT_DOCS[0]}" "$NEW_ARCHIVE/assets/${ASSET_LAYOUT_DOCS[0]##*/}" || COPY_CHECK_FAILED=1
        cmp -s "$SKETCH_DIR/partitions.csv" "$NEW_ARCHIVE/partitions.csv" || COPY_CHECK_FAILED=1
    fi

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

    local_unused=0
    ARCHIVE_HASH_FILES=(snapack.ino.bootloader.bin snapack.ino.partitions.bin boot_app0.bin snapack.ino.bin)
    if [[ -d "$SKETCH_DIR/assets" ]]; then ARCHIVE_HASH_FILES+=(assets/snapack_assets.bin assets/ASSET_MANIFEST_SHA256.txt "assets/${ASSET_LAYOUT_DOCS[0]##*/}" partitions.csv RELEASE_FORMAT); fi
    if ! (
        cd "$NEW_ARCHIVE"
        sha256sum "${ARCHIVE_HASH_FILES[@]}" > SHA256SUMS
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

    VERIFICATION_DIAGNOSTIC="$NEW_ARCHIVE/verification_diagnostic.tmp"
    if ! verify_firmware_archive "$NEW_ARCHIVE" quiet > "$VERIFICATION_DIAGNOSTIC" 2>&1; then
        mv -- "$VERIFICATION_DIAGNOSTIC" "$NEW_ARCHIVE/FAILED_VERIFICATION.txt"
        printf "Archive verification failed at %s. Flash prohibited.\n" "$(date -Is)" >> "$NEW_ARCHIVE/FAILED_VERIFICATION.txt"
        clear_screen
        print_header "SNAPACK PRE-FLASH VERIFICATION"
        echo -e "${GR} = = > Required firmware files ........ PASS${NC}"
        echo -e "${GR} = = > Archive directory created ...... PASS${NC}"
        echo -e "${GR} = = > Archived copies verified ....... PASS${NC}"
        echo -e "${GR} = = > SHA-256 manifest generated ..... PASS${NC}"
        echo -e "${RE} = = > Firmware integrity check ....... FAIL${NC}"
        echo
        print_error "New Archive Did Not Pass Its Own Integrity Check -- FLASH REFUSED."
        cat -- "$NEW_ARCHIVE/FAILED_VERIFICATION.txt"
        print_warn "Failed archive retained for inspection: $NEW_ARCHIVE"
        pause_screen
        continue
    fi

    rm -f -- "$VERIFICATION_DIAGNOSTIC"

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
        if [[ -d "$SKETCH_DIR/assets" ]]; then
            echo "0xA00000 assets/snapack_assets.bin"
            echo "Asset SHA-256: $(sha256sum "$NEW_ARCHIVE/assets/snapack_assets.bin" | awk '{print $1}')"
        fi
    } > "$NEW_ARCHIVE/INFO.txt"

    # Optional description was collected on the Proposed Operation screen before the
    # final commit. It becomes persistent only now that the archive really exists. NOTES.txt
    # remains deliberately outside SHA256SUMS so metadata edits do not alter firmware identity.
    if [[ -n "$ARCHIVE_NOTE" ]]; then
        if ! printf '%s\n' "$ARCHIVE_NOTE" > "$NEW_ARCHIVE/NOTES.txt"; then
            print_error "Could Not Write NOTES.txt."
            print_warn "Firmware Archive Remains Valid; Description Was Not Saved."
            ARCHIVE_NOTE=""
        fi
    fi

    # Preserve release validator evidence for IDE-export archives as well.
    if [[ "$BUILD_ORIGIN" == "Arduino IDE export" ]]; then
        if [[ ! -s "$VALIDATION_LOG" ]] || ! cp -- "$VALIDATION_LOG" "$NEW_ARCHIVE/SOURCE_VALIDATION.txt"; then
            print_error "Source validation evidence could not be archived -- FLASH REFUSED."
            pause_screen
            continue
        fi
        printf '%s\n' "IDE export: operator confirmed $RELEASE_STEP; binary/source equivalence not independently established." > "$NEW_ARCHIVE/BUILD_PROVENANCE.txt" || { pause_screen; continue; }
        (cd "$NEW_ARCHIVE" && sha256sum SOURCE_VALIDATION.txt BUILD_PROVENANCE.txt > SOURCE_SHA256SUMS && sha256sum -c SOURCE_SHA256SUMS >/dev/null) || { print_error "IDE provenance hash failed; FLASH REFUSED."; pause_screen; continue; }
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
    if (( ARCHIVE_ONLY == 1 )); then
        echo -e "${CY} = = > Controller check ............... NOT REQUIRED (NO FLASH)${NC}"
    else
        echo -e "${GR} = = > ESP32-S3 communication ......... PASS${NC}"
        echo -e "${GR} = = > Initial controller check ......... PASS${NC}"
    fi
    echo
    print_info "Archive:        ${GREEN}$NEW_ARCHIVE${NC}"
    if (( ARCHIVE_ONLY == 0 )); then
        print_info "Controller MAC: ${GREEN}$CONTROLLER_MAC${NC}"
        print_info "Trust Status:   ${GREEN}$CONTROLLER_TRUST${NC}"
    fi
    if [[ -n "$ARCHIVE_NOTE" ]]; then
        print_info "Description:    ${WHITE}$ARCHIVE_NOTE${NC}"
    fi
    echo
    if (( ARCHIVE_ONLY == 1 )); then
        print_good "ARCHIVE VERIFIED; NO FLASH REQUESTED"
    else
        print_good "ARCHIVE VERIFIED AND READY TO FLASH"
        print_warn "No Firmware Has Been Written Yet."
    fi
    if (( ARCHIVE_ONLY == 1 )); then
        print_good "$RELEASE_STEP BINs archived and hash-verified. No device flash requested or attempted."
        print_warn "Archive is waiting; no PENDING/GOOD state or .last_flash update was made."
        if [[ "${ZIP_INSTALL_MODE:-0}" == 1 ]]; then
            if [[ -f "$RELEASE_ZIP" && ! -e "$RELEASE_ZIP_DEST" && ! -L "$RELEASE_ZIP_DEST" ]]; then
                if mv -n -- "$RELEASE_ZIP" "$RELEASE_ZIP_DEST" && [[ ! -e "$RELEASE_ZIP" && -f "$RELEASE_ZIP_DEST" ]]; then
                    print_good "Release ZIP moved from New to Archive: $RELEASE_ZIP_NAME"
                else
                    print_error "Could not move release ZIP to Archive; leave it in New for manual inspection."
                fi
            else
                print_error "Release ZIP missing or archive destination occupied; no ZIP move attempted."
            fi
        fi
        # Archive-only must also record the exact verified build. Previously this
        # branch continued before writing .ready_to_flash, so the operator had no
        # resume target and was led back through the archive-creation workflow.
        if ! printf '%s\n' "$NEW_ARCHIVE" > "$ARCHIVE_DIR/.ready_to_flash"; then
            print_error "Archive succeeded, but the resume pointer could not be saved."
            print_warn "Do not rebuild. Existing archive: $NEW_ARCHIVE"
        else
            print_good "NEXT: Select main-menu option 6 to FLASH this exact archive."
            print_good "Option 6 verifies the four BIN hashes; it does NOT compile or archive again."
            print_info "Resume archive: $NEW_ARCHIVE"
        fi
        pause_screen
        continue
    fi
    # Save the exact archive identity before probing USB. A later run can resume
    # this same hash-verified four-BIN set without rebuilding or guessing newest.
    if ! printf '%s\n' "$NEW_ARCHIVE" > "$ARCHIVE_DIR/.ready_to_flash"; then
        print_error "Cannot record resumable archive; no flash attempted."
        pause_screen
        continue
    fi
    if ! wait_for_controller_after_build; then
        print_warn "Verified archive retained for main-menu Resume option. No flash attempted."
        pause_screen
        continue
    fi
    if ! evaluate_previous_pending_flash; then pause_screen; continue; fi
    print_info "Next stage: final controller recheck, then flash write after Enter."
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
    # PENDING therefore means exactly: written successfully, awaiting evaluation.
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

    if [[ -f "$ARCHIVE_DIR/.ready_to_flash" ]] && [[ "$(cat "$ARCHIVE_DIR/.ready_to_flash")" == "$NEW_ARCHIVE" ]]; then
        rm -f -- "$ARCHIVE_DIR/.ready_to_flash"
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
# 6) RESUME THE EXACT VERIFIED BUILD, WITHOUT RECOMPILING
# =========================================================================================
6)
    READY_FILE="$ARCHIVE_DIR/.ready_to_flash"
    if [[ ! -f "$READY_FILE" ]]; then
        print_warn "No Interrupted Verified Build Is Recorded."
        pause_screen
        continue
    fi
    READY_ARCHIVE=$(cat -- "$READY_FILE") || { pause_screen; continue; }
    # Only accept a direct child of the archive root; never trust an arbitrary
    # path from a stale or modified pointer file.
    if [[ "$(dirname -- "$READY_ARCHIVE")" != "$ARCHIVE_DIR" ]] ||
       [[ ! -d "$READY_ARCHIVE" ]] ||
       ! verify_firmware_archive "$READY_ARCHIVE" quiet; then
        print_error "Saved build path or SHA-256 verification failed; flash refused."
        pause_screen
        continue
    fi
    clear_screen
    print_header "RESUME VERIFIED FIRMWARE BUILD"
    print_info "Exact archive: $READY_ARCHIVE"
    print_good "SHA-256 verified. Compilation will NOT run."
    echo -ne "Press Enter to check controller and prepare flash, or 0 to cancel: "
    read -r CONFIRM || continue
    [[ -z "$CONFIRM" ]] || continue
    if ! wait_for_controller_after_build; then
        print_warn "Archive retained for later resume."
        pause_screen
        continue
    fi
    if ! evaluate_previous_pending_flash; then pause_screen; continue; fi
    echo -ne "Press Enter to FLASH this exact verified archive, or 0 to cancel: "
    read -r CONFIRM || continue
    [[ -z "$CONFIRM" ]] || continue
    if ! flash_directory "$READY_ARCHIVE"; then
        print_error "Flash unsuccessful; verified archive remains resumable."
        pause_screen
        continue
    fi
    if ! printf 'PENDING\n' > "$READY_ARCHIVE/STATUS"; then
        print_error "Flash succeeded, but STATUS bookkeeping failed; inspect manually."
        pause_screen
        continue
    fi
    if ! printf '%s\n' "$READY_ARCHIVE" > "$STATE_FILE"; then
        print_error "Flash succeeded, but .last_flash bookkeeping failed; inspect manually."
        pause_screen
        continue
    fi
    rm -f -- "$READY_FILE"
    print_good "Flash succeeded. Archived build marked PENDING."
    pause_screen
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
