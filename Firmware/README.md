# SNAPACK Firmware

This directory contains the firmware development, recovery, flashing,
and preservation material for the **SNAPACK** project and its Elecrow
2.1-inch round ESP32-S3 display/controller.

The contents are intentionally separated by purpose. The current
development firmware, the original known-good Elecrow baseline, the
SnapFlash utility, and historical binary backups are not
interchangeable. Each directory exists to answer a different recovery or
development need.

------------------------------------------------------------------------

## Current Working Firmware

**Purpose:** Active SNAPACK firmware development and the most relevant
current project checkpoint.

This is where to look first for the firmware that represents the current
state of SNAPACK development. Expect this area to contain the current
source/configuration, release or checkpoint documentation, and recovery
material associated with useful working firmware states.

This area includes:

-   current or recently accepted SNAPACK source/configuration;
-   release/checkpoint README files and validation information;
-   exported firmware artifacts associated with working checkpoints;
-   current partition/layout information;
-   packaged recovery material;
-   selected developer-reference releases that remain useful even after
    development has moved forward.

A preserved **Developer's Edition** is also maintained in this area. It
is a deliberately retained developer/diagnostic reference package, not
an indication that its Step number is the newest firmware. Its package
contains the corresponding source "recipe," known-good binary backup,
and documentation needed to understand or reproduce that
developer-oriented checkpoint.

Because this is the **moving development area**, its contents can change
as SNAPACK firmware advances.

Read the `README.md` inside this directory for the detailed description
of the current checkpoint and any specially preserved packages.

------------------------------------------------------------------------

## Flash Utility

**Purpose:** Safely compile, archive, verify, flash, restore, and manage
SNAPACK firmware.

This directory contains **SnapFlash**, the SNAPACK firmware
archive/recovery utility and its documentation.

SnapFlash exists to make firmware changes recoverable rather than
treating each new flash as a one-way operation. Depending on the
selected workflow, it can compile or use prepared firmware, create
verified archives, maintain flash-status information, check
controller/serial safety conditions, flash an ESP32-S3, and restore
previously archived firmware.

Expect this directory to contain items such as:

-   the current SnapFlash shell script;
-   `README.md` describing operation and configuration;
-   SHA-256/checksum information for distributed releases;
-   packaged SnapFlash releases or historical utility versions where
    retained.

SnapFlash contains deliberate safety gates. A stopped flash, archive,
compile, or validation operation should be investigated.
once SnapFlash is working, leave the project files alone.
Cleaning, moving, renaming, or deleting files in directories SnapFlash
is actively snapshotting or validating can correctly trigger its
integrity safeguards.

Read the `README.md` inside the Flash Utility directory before using
SnapFlash on hardware.

------------------------------------------------------------------------

## Known-Good Elecrow Baseline

**Purpose:** Preserve the original proven display/firmware development
baseline independently of ongoing SNAPACK development.

This directory is the stable reference point used when SNAPACK display
development began from the working Elecrow environment.

It is intentionally separate from Current Working Firmware. Current
Working Firmware moves forward; the Known-Good Elecrow Baseline should
remain a preserved reference.

This area contains the source, configuration, documentation,
library/build information, or other material needed to understand and
reproduce the known-good Elecrow starting state.

Its value comes from remaining a **known-good
baseline**.

------------------------------------------------------------------------

## BIN Backup

**Purpose:** Preserve compiled firmware images and recovery checkpoints
independently of editable source.

This directory contains binary firmware backups accumulated during
SNAPACK development.

These backups are valuable when a later source revision does not
compile, a development experiment fails, or a previously working
firmware state needs to be restored without reconstructing and
recompiling that historical source tree.

Depending on the age and type of the backup, expect to find:

-   ESP32-S3 application binaries;
-   bootloader binaries;
-   partition-table binaries;
-   `boot_app0` or related flash components;
-   asset-partition images for firmware generations that use a separate
    asset partition;
-   archive notes, status/provenance information, timestamps, or release
    identity;
-   SHA-256 checksum manifests;
-   complete 16 MB device images where explicitly captured as
    full-device recovery backups.

A normal firmware archive and a **full 16 MB device image** are
different recovery artifacts.
Do not assume every BIN backup is a complete raw-device image.

When restoring an archive, use its recorded flash layout and
accompanying documentation

------------------------------------------------------------------------

## Target Hardware

The primary SNAPACK display/controller platform is:

-   **Elecrow CrowPanel 2.1-inch HMI**
-   Model **DHE03921D**
-   **ESP32-S3**
-   480 × 480 round IPS display
-   16 MB flash
-   8 MB PSRAM
-   touchscreen
-   rotary encoder

The established SNAPACK development environment has used ESP32 Arduino
Core **2.0.14**, LVGL **8.3.6**, and GFX Library for Arduino **1.3.1**.
Individual firmware checkpoints should be treated as authoritative for
their own exact build requirements.

------------------------------------------------------------------------

## Recovery Philosophy

SNAPACK firmware development deliberately preserves multiple levels of
recovery.

1.  **Current Working Firmware** preserves the active development state.
2.  **BIN Backup** preserves compiled states that can survive later
    source or build failures.
3.  **Known-Good Elecrow Baseline** preserves the original proven
    development reference.
4.  **Full-device images**, where present and explicitly identified,
    provide a deeper recovery mechanism.
5.  **SnapFlash** provides the controlled workflow used to verify,
    archive, flash, and restore these artifacts.

Read the README, release notes, archive notes, manifests, and
checksum files that accompany the specific artifact before modifying or
flashing it.

------------------------------------------------------------------------

This root README is an orientation document. The README and release
documentation inside each subdirectory should be considered more
specific and authoritative for the artifacts stored there.
