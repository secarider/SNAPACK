# SNAPACK FIRMWARE BIN BACKUP

This directory contains archived, directly flashable SNAPACK firmware versions created by the flash_snapack utility.

Each dated subdirectory represents one firmware version and contains the complete four-file ESP32-S3 flash set:

snapack.ino.bootloader.bin   -> flash address 0x0000
snapack.ino.partitions.bin   -> flash address 0x8000
boot_app0.bin                -> flash address 0xE000
snapack.ino.bin              -> flash address 0x10000

These files are archived BEFORE that firmware version is flashed. The flash_snapack utility then flashes the archived copies themselves, ensuring that the archived files are exactly the files sent to the display.

Each archive also contains:

STATUS    - PENDING, GOOD, or BAD
INFO.txt  - creation information and flash configuration

PENDING means the firmware has been flashed but has not yet been evaluated.

On the next use of flash_snapack, the previous PENDING version is marked GOOD or BAD 
based on the physical results of that flash.

BAD versions are retained rather than automatically deleted so they remain available for 
troubleshooting or later reevaluation.

Archived firmware can be selected through flash_snapack and 
restored directly to the display without recompiling the 
original source code or depending on the current Arduino library/toolchain versions.

The hidden .last_flash file records which archived firmware set was most recently flashed to the physical display.

Normal use:

From /home/valued/Arduino/snapack:

```
  ./flash_snapack
```

Do not manually alter individual BIN files inside an archived set. The four files together constitute the restorable firmware package.


Why SNAPACK Uses esptool --no-stub

The SNAPACK display uses an ESP32-S3 whose particular USB/flash configuration 
proved unreliable when flashing through the Arduino IDE or with esptool's normal RAM-stub loader. 
During development, those methods produced failed or inconsistent transfers, 
while direct ROM-bootloader communication using esptool --no-stub proved reliable.

For that reason, SNAPACK firmware is compiled/exported with the Arduino IDE, but the resulting bootloader, 
partition table, boot-app, and application binaries are flashed from the command line using esptool 
--no-stub at their required addresses. This is a hardware-specific reliability workaround, 
not a requirement of SNAPACK firmware in general.

Backup path to the *.BIN'S being backed up and archive path to where we're storing it are hardwired inside this script. 
Open it with any text editor to see those paths and change them to your paths if your paths are not the same.









