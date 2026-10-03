# SNAPACK --- Current Working Firmware

This directory contains the **current working SNAPACK display firmware
development checkpoint** for the Elecrow 2.1-inch round ESP32-S3
display.

This firmware is derived from the separately preserved **Known-Good
Elecrow Display Baseline** and represents the current state of SNAPACK
firmware development.

Files in this directory may change as SNAPACK hardware is verified,
measurements are brought online, and display functionality is developed.

The Known-Good Elecrow Display Baseline should remain unchanged as the
proven recovery point.

------------------------------------------------------------------------

## Hardware

Display:

-   Elecrow CrowPanel 2.1-inch HMI
-   Model: DHE03921D
-   480 × 480 round IPS display
-   ESP32-S3
-   16 MB flash
-   8 MB PSRAM
-   Rotary encoder
-   Touchscreen

The ESP32-S3 was detected by esptool as:

-   ESP32-S3 QFN56, revision v0.2
-   40 MHz crystal
-   8 MB embedded PSRAM
-   16 MB SPI flash
-   USB Serial/JTAG

------------------------------------------------------------------------

## Known-Good Build Environment

The following environment successfully compiles and runs the SNAPACK
firmware on the physical display:

-   ESP32 Arduino Core: **2.0.14**
-   Board: **ESP32S3 Dev Module**
-   Flash Size: **16 MB**
-   PSRAM: **OPI PSRAM**
-   LVGL: **8.3.6**
-   GFX Library for Arduino: **1.3.1**

The Elecrow-provided library versions are retained from the known-good
baseline.

------------------------------------------------------------------------

## Partition Layout

The SNAPACK application uses the custom 16 MB partition layout
established during the Known-Good Elecrow Display Baseline.

The custom `partitions.csv` is included in this directory.

The application partition begins at:

    0x10000

and provides:

    0xFF0000 bytes

for the application.

Arduino reports the resulting capacity as:

    Maximum program storage space: 16711680 bytes

------------------------------------------------------------------------

## Current Working Source

The current editable firmware source is:

    snapack.ino

The current custom partition configuration is:

    partitions.csv

These files represent the source/configuration state corresponding to
this firmware checkpoint.

------------------------------------------------------------------------

## Current Working Firmware Backup

This directory is the moving home of the current SNAPACK firmware
checkpoint and its associated recovery material.

As development advances, the current source/configuration and the
corresponding exported firmware artifacts should be preserved before
further changes are made. Historical or specially designated recovery
packages may also be retained here when they have continuing development
value.

------------------------------------------------------------------------

## Developer's Edition --- Step90 Diagnostic Baseline

A separately packaged **SNAPACK Step90 Developer's Edition** is
preserved in this Current Working Firmware area as a public
developer/diagnostic baseline.

The Developer's Edition is **not the current editable firmware
revision**. It is an intentionally preserved Step90 development
checkpoint containing the diagnostic instrumentation and recovery
material that established much of the SNAPACK monitoring,
event-management, sensor-acquisition, and operator-interface
architecture.

The package is:

    Developers_Edition.zip

It contains four coordinated items:

    README_START_HERE.txt.md
    README_STEP90_DEVELOPER_DIAGNOSTIC.txt
    snapack_ui_step90_developer_diagnostic.zip
    snapack_ui_step90_developer_diagnostic_bin_backup.zip

The source ZIP is the complete editable Step90 firmware package --- the
**recipe** --- and is the correct starting point for source inspection
or reconstruction of that release.

The binary-backup ZIP is the corresponding known-good exported
flash-image set. It preserves the coordinated ESP32-S3 firmware
binaries, recorded flash layout, archive notes/status, and integrity
checksums. The source and binary backup serve different purposes and
should be kept together with the two accompanying README files.

Step90 is especially useful as a developer reference because it exposes
the diagnostic instrumentation used during SNAPACK development,
including system, ADS/I2C, cell, thermal, current, event, settings, UI,
and Wi-Fi diagnostics.

The Developer's Edition intentionally excludes the SNAPACK owner's
private Wi-Fi credentials. Its source package supplies
`SNAPACK_LOCAL_ONLY_WIFI.example.h` for local developer configuration.

A companion SHA-256 file is provided beside the Developer's Edition
archive:

    Developers_Edition.zip.sha256

The SHA-256 of the currently published Developer's Edition archive is:

    e7fff6d2ef3c1c65eb9ccc76be8663bf6f5ff100fb2f3ee003621351d74ec306

Keep the Developer's Edition ZIP and its checksum together. For detailed
release identity, flash layout, validation notes, and developer
instructions, begin with `README_START_HERE.txt.md` inside the archive.

------------------------------------------------------------------------

## Development Workflow

Current development workflow:

1.  Edit `snapack.ino`.

2.  Save the source file.

3.  Open/reopen `snapack.ino` in Arduino IDE as necessary.

4.  Run **Verify** in Arduino IDE.

5.  Use:

        Sketch → Export Compiled Binary

6.  Flash the exported binaries using esptool.

7.  After a useful working checkpoint is reached, update the files in
    this directory and replace the Current Working Firmware archive.

------------------------------------------------------------------------

## Flashing

### Development-Machine Note

On the development machine used for SNAPACK, Arduino IDE's conventional
upload process has been unreliable during sustained transfer of the
large application image.

Arduino IDE successfully:

-   detects the ESP32-S3,
-   enters the bootloader,
-   begins flashing,
-   and writes initial flash regions,

but sustained transfer of the large application image has previously
failed.

The same general behavior occurred while reading the original 16 MB
factory flash: stub-based esptool transfers failed, while a `--no-stub`
transfer successfully read the complete flash.

Using esptool's ROM-loader path with:

    --no-stub

has proven reliable on this development machine/display combination.

------------------------------------------------------------------------

## Working Flash Command

The following command structure has successfully flashed SNAPACK
firmware on the development system:

``` bash
~/.local/bin/esptool --no-stub --chip esp32s3 --port /dev/ttyACM0 \
  write-flash --flash-mode dio --flash-freq 80m --flash-size 16MB \
  0x0000  /home/valued/Arduino/snapack/build/esp32.esp32.esp32s3/snapack.ino.bootloader.bin \
  0x8000  /home/valued/Arduino/snapack/build/esp32.esp32.esp32s3/snapack.ino.partitions.bin \
  0xe000  /home/valued/.arduino15/packages/esp32/hardware/esp32/2.0.14/tools/partitions/boot_app0.bin \
  0x10000 /home/valued/Arduino/snapack/build/esp32.esp32.esp32s3/snapack.ino.bin
```

------------------------------------------------------------------------

## Purpose of This Directory

This directory is the **moving development checkpoint** for SNAPACK
firmware and the home of selected recovery/developer artifacts that are
intentionally preserved alongside it.

When firmware reaches a useful working state, the current source,
partition configuration, and exported build artifacts should be saved
here before further development.

The preserved **Step90 Developer's Edition** provides a documented
developer/diagnostic baseline and known-good source/BIN reference. It
should not be confused with the newest current firmware revision.

The separate **Known-Good Elecrow Display Baseline** remains the
original proven recovery point and should not be overwritten by ongoing
SNAPACK development.
