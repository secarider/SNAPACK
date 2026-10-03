\
# SNAPACK SnapFlash Utility

**Release:** SnapFlash v1.2.32  
**Target:** SNAPACK controller based on the Elecrow DHE03921D 2.1-inch round 480×480 ESP32-S3 display/controller

SnapFlash is a Bash-based firmware installation, compilation, archival, flashing, restoration, and full-device recovery utility developed for the SNAPACK project. Its central purpose is to preserve verified compiled firmware independently of whether an older source tree can still be compiled later.

A source tree records how firmware was made. A verified firmware archive records what can actually be flashed. A verified full-device image records the complete flash state captured from the controller. SnapFlash keeps those recovery artifacts distinct.

## Hardware warning

**Do not assume SNAPACK firmware archives, flash addresses, partition layouts, full-device images, or this utility are safe for another controller.**

Even hardware carrying the same nominal model designation should be checked for flash size, hardware revision, partition layout, and firmware compatibility before writing it.

A SHA-256 checksum proves file integrity. It does not prove hardware compatibility.

## SnapFlash v1.2.32 main menu

The public main menu is:

1. **Install Release ZIP, Compile And Archive (NO FLASH)**
2. **Compile Current Source, Archive And Flash**
3. **Archive And Flash Existing IDE Export**
4. **Restore Archived Firmware**
5. **Recovery And Archive Tools**
6. **Flash Prepared Archive (NO RECOMPILE)**
0. **Exit**

The Recovery And Archive Tools submenu provides:

1. Restore Full 16 MB Device Image
2. Capture Full 16 MB Device Image
3. Validate And Archive Existing Binary Files (NO FLASH)
0. Return To Main Menu

### Hidden option 24

Entering `24` at the main-menu prompt invokes the unattended release path:

**Install release ZIP → compile → archive → verify → controller safety checks → flash**

Option 24 is deliberately not displayed in the public menu. Selecting it is itself authorization to flash.

In option 24:

- the previous PENDING flash is presumed successful and is marked GOOD;
- no archive-description question is asked;
- no final flash-confirmation question is asked;
- successful checks continue automatically;
- a failure remains authoritative and stops the operation;
- the controller must already be in the trusted-controller registry;
- archive integrity, compatibility, controller identity/trust, and serial-port safety gates remain active;
- no screen-clearing operation is performed, preserving terminal scrollback;
- exactly one release ZIP must be present in the incoming `Archive/New` directory.

Option 24 does not convert failed validation into an interactive override. Correct the reported problem and run it again.

## Archive-first design

New firmware is preserved before it is written.

SnapFlash copies the required firmware components into a timestamped archive, byte-compares archived copies against their sources, generates a SHA-256 manifest, and verifies the archive before flashing. Flash operations use the verified archived copies rather than loose build-directory files.

A failed integrity or compatibility check prevents flashing. A failed flash is not marked as successfully installed.

For the historical/non-asset layout, the core flash set is:

- `0x0000` — `snapack.ino.bootloader.bin`
- `0x8000` — `snapack.ino.partitions.bin`
- `0xE000` — `boot_app0.bin`
- `0x10000` — `snapack.ino.bin`

For the current asset release format, SnapFlash also validates and archives the asset package and writes:

- `0xA00000` — `assets/snapack_assets.bin`

The script validates the partition binary and release-format evidence before accepting an asset release.

## Firmware status

After a successful firmware write, an archive is initially marked:

- **PENDING** — the write succeeded but physical/functional operation has not yet been confirmed;
- **GOOD** — subsequently confirmed as working;
- **BAD** — subsequently determined to be bad and retained for recovery/history.

Normal interactive write workflows ask about a previous PENDING flash immediately before another device-write operation. Merely opening SnapFlash, browsing archives, or performing non-write work does not force that judgment.

Option 24 is the deliberate exception: selecting it means the previous PENDING flash is presumed successful and may be marked GOOD without prompting.

## Prepared archives

Archive-only workflows can leave a verified archive ready for later flashing. Main-menu option 6 resumes the exact prepared archive without recompiling or creating another archive.

This avoids rebuilding merely because the controller was unavailable or because flashing was intentionally deferred.

## Release ZIP installation

Option 1 installs a release ZIP, compiles it using the configured Arduino AppImage environment, verifies the result, and archives it without flashing.

The incoming ZIP queue is derived from `SKETCH_DIR`:

`$SKETCH_DIR/recovery/Firm_Ware/Current_Working_Firmware/Archive/New`

SnapFlash requires exactly one ZIP in that directory for a release installation. It does not guess which ZIP is intended from timestamps.

The managed sketch and external UI source are backed up before replacement. Installation and compilation failures are designed to stop before flashing, with source restoration attempted where applicable.

### Do Not “Help” SnapFlash by Cleaning Up While It Is Running

Leave the files alone while SnapFlash is working.

During development, several apparently mysterious SnapFlash failures were eventually traced to an overly fastidious operator who decided that the middle of an active compile/archive/verification operation was an excellent time to go back and tidy up old files and temporary clutter.

It was not.

SnapFlash was examining and snapshotting those directories at the same time the user was enthusiastically cleaning them. The resulting directory changes correctly triggered GNU `tar` and SnapFlash's source-integrity safeguards, stopping the operation because the source being verified had changed underneath it.

Several minutes of investigation later, SnapFlash was exonerated. **The user did it.**

Therefore: once SnapFlash begins an operation, resist the urge to organize, clean, rename, move, delete, or otherwise improve anything in the SNAPACK project/source directories until SnapFlash finishes.

If SnapFlash reports that a file or directory changed while it was being read—and you were “just cleaning up a few things”—stop cleaning, leave everything alone, and run it again.

## Full 16 MiB device images

SnapFlash can capture and restore a raw 16 MiB ESP32-S3 flash image as a separate recovery artifact.

A captured image is required to be exactly 16,777,216 bytes. SnapFlash generates and verifies SHA-256 integrity information for the image.

A full-image restore is materially different from a normal firmware flash: it writes the complete flash image beginning at `0x00000000`.

## Why `--no-stub` is used

The SNAPACK recovery workflow uses `esptool --no-stub`. This was established during physical recovery work on the SNAPACK controller after a stub-based operation proved unreliable. The no-stub path subsequently produced the complete factory-firmware backup successfully.

## Controller and serial-port safety

SnapFlash uses a trusted-controller registry as an accidental-flash gate. A controller MAC that has not previously been approved must be handled through the normal interactive workflow before hidden option 24 can use it.

Before controller communication and again immediately before a flash write, SnapFlash checks serial-port availability. A busy port causes the operation to stop rather than automatically killing the process that owns it.

These gates reduce accidental writes; they do not establish that arbitrary hardware is electrically or firmware-compatible with SNAPACK.

# Local path configuration

SnapFlash v1.2.32 was developed on one Linux workstation and intentionally contains several machine-specific paths near the beginning of `snapflash.sh`.

**A different user should inspect and, where necessary, edit these configuration variables before running the utility. Do not globally search-and-replace `/home/valued` throughout the script. Change the configuration assignments near the top of `snapflash.sh`.**

The shipped v1.2.32 values are:

| Variable | Shipped value | What another installation may need to change |
|---|---|---|
| `BUILD_DIR` | `/home/valued/Arduino/snapack/build/esp32.esp32.esp32s3` | Arduino IDE export/build output directory |
| `ARCHIVE_DIR` | `/home/valued/Arduino/snapack/recovery/bin_backup` | Permanent timestamped firmware archive directory |
| `IMAGE_ARCHIVE_DIR` | `/home/valued/Arduino/snapack/recovery/device_images` | Full 16 MiB device-image archive directory |
| `TRUSTED_DEVICES_FILE` | `/home/valued/Arduino/snapack/recovery/trusted_devices.txt` | Trusted-controller registry |
| `BOOT_APP0` | `/home/valued/.arduino15/packages/esp32/hardware/esp32/2.0.14/tools/partitions/boot_app0.bin` | `boot_app0.bin` belonging to the installed ESP32 Arduino core |
| `ESPTOOL` | `$HOME/.local/bin/esptool` | esptool executable if installed elsewhere |
| `PORT` | `/dev/ttyACM0` | Actual serial device assigned to the controller |
| `SKETCH_DIR` | `/home/valued/Arduino/snapack` | SNAPACK sketch/project directory |
| `UI_LIB_DIR` | `/home/valued/Arduino/libraries/UI` | External SNAPACK UI library/source directory |
| `ARDUINO_APPIMAGE` | `/home/valued/Appimages/arduino_ide.appimage` | Arduino IDE AppImage used by the isolated compiler workflow |

### Important path notes

`SKETCH_DIR` is especially important because SnapFlash derives additional locations beneath it, including the incoming release ZIP queue. Change `SKETCH_DIR` correctly rather than independently editing every derived path.

`BOOT_APP0` is not only username-specific. The shipped path names ESP32 Arduino core version `2.0.14`. A machine using a different installed core version must point `BOOT_APP0` at the matching file for that installation. Do not blindly copy the `2.0.14` path.

`ESPTOOL` already uses `$HOME`, so it is more portable than the literal `/home/valued/...` paths, but it still assumes esptool is installed in `$HOME/.local/bin`.

`PORT=/dev/ttyACM0` is not guaranteed. Linux may assign another device such as `/dev/ttyACM1`. Confirm the controller's actual device before flashing.

`FQBN` is also frozen near the path/configuration block. It records the verified SNAPACK ESP32-S3 Arduino compilation options. It is hardware/build configuration rather than a filesystem path and should not be casually changed to accommodate a different machine.

SnapFlash creates its configured archive/image directories when needed, but the sketch, UI source, Arduino AppImage, ESP32 core component, esptool executable, and serial device must resolve correctly for the requested operation.

## Dependencies and environment

The utility is designed for a Linux Bash environment and expects normal command-line utilities used by the script, including SHA-256 and archive/file-management tools, plus the configured Arduino AppImage and esptool installation for operations that need them.

It does **not** intentionally update the Arduino IDE, ESP32 core, or libraries as part of normal operation. The compilation configuration is treated as a controlled environment.

## Distribution integrity

This repository package contains:

- `snapflash.sh` — SnapFlash v1.2.32
- `README.md` — this documentation
- `SHA256SUMS` — SHA-256 hashes for the distributed script and README

Verify the extracted files from inside the package directory with:

```bash
sha256sum -c SHA256SUMS
```

A separately distributed checksum for the ZIP can be verified with:

```bash
sha256sum -c SNAPACK_SnapFlash_v1.2.32.zip.sha256
```

## Running SnapFlash

After extraction:

```bash
chmod +x snapflash.sh
./snapflash.sh
```

Review the local path configuration before the first run on a different workstation.

## Recovery principle

SnapFlash is designed around one rule: **preserve the exact verified bytes needed for recovery before depending on the next flash.**

That makes an older working firmware recoverable even when future source, libraries, toolchains, or build environments have changed.
