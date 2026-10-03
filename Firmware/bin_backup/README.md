# SNAPACK Firmware --- BIN Backup

This directory contains preserved, directly restorable **SNAPACK
firmware binary archives** created during firmware development and
maintained by the SnapFlash archive/recovery workflow.

Its primary purpose is simple: a known firmware state should remain
recoverable even if later source code no longer compiles, libraries
change, a development experiment fails, or the current working tree has
moved far beyond that version.

------------------------------------------------------------------------

## What to Expect Here

Most normal firmware backups are stored in dated or otherwise identified
archive directories. Each archive represents one compiled SNAPACK
firmware state.

The traditional ESP32-S3 flash set consists of:

  File                             Flash Address Purpose
  ------------------------------ --------------- ----------------------------------
  `snapack.ino.bootloader.bin`          `0x0000` ESP32-S3 bootloader
  `snapack.ino.partitions.bin`          `0x8000` Partition table
  `boot_app0.bin`                       `0xE000` Arduino boot application support
  `snapack.ino.bin`                    `0x10000` SNAPACK application firmware

Modern SNAPACK firmware generations may also contain a separate asset
image:

  -------------------------------------------------------------------------
  File                                  Flash Address Purpose
  ---------------------- ---------------------------- ---------------------
  `snapack_assets.bin`                     `0xA00000` SNAPACK display/UI
                                                      asset partition

  -------------------------------------------------------------------------

Not every historical archive uses the same firmware layout. **The
metadata and flash layout stored with the individual archive are
authoritative for that archive.** Do not add, remove, or relocate images
merely because a different SNAPACK generation used another layout.

------------------------------------------------------------------------

## Archive-Before-Flash Design

SnapFlash archives and verifies the firmware set **before** it is
written to the physical controller.

The archived copies are then the copies used for the flash operation.
This makes the archive a record of the actual firmware set intended for
the display rather than an unrelated backup made afterward.

This archive-first design is one of the central SNAPACK recovery
safeguards.

------------------------------------------------------------------------

## Archive Contents

Depending on the age and firmware generation, an archive may contain:

-   bootloader, partition-table, boot-app, and application BIN files;
-   a separate SNAPACK asset-partition BIN;
-   `SHA256SUMS` or equivalent integrity information;
-   `STATUS`;
-   `INFO.txt`, notes, release identity, or other provenance
    information;
-   source/build fingerprints or validation records;
-   flash-layout information;
-   additional recovery metadata created by the SnapFlash version that
    produced the archive.

Older archives may contain less metadata than newer ones. That does not
by itself make them invalid.

Do not manually alter individual BIN files, checksums, or metadata
inside a verified archive. The coordinated files constitute the
restorable firmware package.

------------------------------------------------------------------------

## Archive Status: PENDING, GOOD, and BAD

SnapFlash uses status information to record the physical result of a
firmware flash.

### `PENDING`

The firmware has been flashed, but the physical result has not yet been
evaluated or recorded.

### `GOOD`

The firmware was accepted as a successful working flash.

### `BAD`

The firmware was determined not to be an acceptable working flash.

BAD archives are deliberately retained. A failed firmware candidate can
still be useful for troubleshooting, comparison, forensic work, or later
reevaluation.

In normal interactive SnapFlash workflows, a previous PENDING flash can
be evaluated on a later run. Some explicitly unattended SnapFlash
workflows have different documented handling of the preceding PENDING
state; consult the current **Flash Utility `README.md`** for the exact
behavior of the SnapFlash version being used.

The hidden `.last_flash` state used by SnapFlash records the archive
most recently associated with a physical flash operation.

------------------------------------------------------------------------

## Restoring an Archived Firmware Version

A major reason this directory exists is to allow an older compiled
firmware state to be restored **without recompiling its original
source**.

That means recovery does not necessarily depend on:

-   the current `snapack.ino`;
-   the current Arduino IDE state;
-   the current library contents;
-   the current source tree;
-   or successfully reconstructing an old build environment.

Use the current **SnapFlash utility** to select, verify, and restore an
appropriate archived firmware package.

Do not manually guess flash addresses from another release. Use the
archive's own recorded layout and the recovery tooling/documentation
associated with it.

------------------------------------------------------------------------

## Normal Firmware Archives vs. Full 16 MB Device Images

These are different kinds of backup.

### Normal firmware archive

A normal archive contains the coordinated firmware images needed to
restore a particular SNAPACK firmware release or checkpoint.

It normally writes only the defined firmware/asset regions associated
with that release.

### Full 16 MB device image

A full-device image is a raw capture of the ESP32-S3's entire 16 MB
flash address space.

A full image may contain substantially more than the normal firmware
set, including data or state from regions that ordinary firmware updates
do not overwrite.

Full-device images are therefore deeper recovery artifacts and should be
clearly identified and handled separately from normal firmware archives.

**Do not assume that a normal BIN archive is a complete 16 MB controller
image.**

SnapFlash provides separate recovery functions for full-device image
capture and restoration where supported.

------------------------------------------------------------------------

## Why SNAPACK Uses `esptool --no-stub`

During SNAPACK development, the Elecrow ESP32-S3 display/controller
proved unreliable during sustained transfers through the Arduino IDE
upload path and through esptool's normal RAM-stub transfer path.

Direct ROM-bootloader communication using:

``` text
--no-stub
```

proved reliable on the development hardware.

For that reason, the established SNAPACK flashing/recovery workflow uses
esptool's `--no-stub` path.

This is a hardware/development-system reliability workaround established
for SNAPACK. It is not a general requirement of all ESP32-S3 firmware.

------------------------------------------------------------------------

## SnapFlash

The current SNAPACK archive/flash/recovery utility is maintained
separately in:

``` text
Flash Utility/
```

Its README documents:

-   current menu operations;
-   archive creation and verification;
-   prepared-archive flashing;
-   firmware restoration;
-   full-device image capture/restoration;
-   controller identity/trust checks;
-   serial-port occupancy safeguards;
-   release ZIP installation;
-   asset-partition handling;
-   local path configuration;
-   and unattended workflow behavior where applicable.

Older documentation may refer to the utility as `flash_snapack`. The
maintained utility is now **SnapFlash**.

Machine-specific paths, serial-device names, Arduino installation paths,
and esptool locations are configured in the utility. Do not assume
another workstation uses the original `/home/valued/...` development
paths.

------------------------------------------------------------------------

## Integrity and Checksums

Where an archive includes SHA-256 checksums, use them.

Checksums are part of the recovery evidence that the stored binary
images have not silently changed since the archive was created.

A checksum mismatch should be treated as an authoritative problem to
investigate, not as an inconvenience to bypass.

Likewise, do not edit a verified archive and then continue treating its
old checksum manifest as valid.

------------------------------------------------------------------------

## Practical Rules

1.  **Do not modify verified archive contents.**
2.  **Do not delete BAD archives merely because they failed on
    hardware.** They may still have diagnostic value.
3.  **Do not assume all SNAPACK generations use the same partition/asset
    layout.**
4.  **Do not confuse a normal firmware archive with a full 16 MB device
    image.**
5.  **Use the archive's own metadata and checksums whenever available.**
6.  **Use SnapFlash for normal restoration rather than manually
    reconstructing an old flash command.**
7.  **Keep known-good recovery points even after newer firmware becomes
    available.**

------------------------------------------------------------------------

## Relationship to the Rest of the Firmware Repository

The SNAPACK firmware repository separates recovery material by purpose:

-   **Current Working Firmware** --- the moving development checkpoint
    and selected preserved developer/reference packages.
-   **Flash Utility** --- SnapFlash and its operating documentation.
-   **Known-Good Elecrow Baseline** --- the original proven
    display/firmware development baseline.
-   **BIN Backup** --- compiled firmware recovery history and binary
    archives.

This directory is therefore the **compiled recovery history**, not the
primary editable source tree.

For current source development, begin in **Current Working Firmware**.
For archive creation, flashing, or restoration, begin with the **Flash
Utility README**.
