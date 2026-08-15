# SNAPACK — Current Working Firmware

This directory contains the **current working SNAPACK display firmware development checkpoint** for the Elecrow 2.1-inch round ESP32-S3 display.

This firmware is derived from the separately preserved **Known-Good Elecrow Display Baseline** and represents the current state of SNAPACK firmware development.

Files in this directory may change as SNAPACK hardware is verified, measurements are brought online, and display functionality is developed.

The Known-Good Elecrow Display Baseline should remain unchanged as the proven recovery point.

---

## Hardware

Display:

* Elecrow CrowPanel 2.1-inch HMI
* Model: DHE03921D
* 480 × 480 round IPS display
* ESP32-S3
* 16 MB flash
* 8 MB PSRAM
* Rotary encoder
* Touchscreen

The ESP32-S3 was detected by esptool as:

* ESP32-S3 QFN56, revision v0.2
* 40 MHz crystal
* 8 MB embedded PSRAM
* 16 MB SPI flash
* USB Serial/JTAG

---

## Known-Good Build Environment

The following environment successfully compiles and runs the SNAPACK firmware on the physical display:

* ESP32 Arduino Core: **2.0.14**
* Board: **ESP32S3 Dev Module**
* Flash Size: **16 MB**
* PSRAM: **OPI PSRAM**
* LVGL: **8.3.6**
* GFX Library for Arduino: **1.3.1**

The Elecrow-provided library versions are retained from the known-good baseline.

---

## Partition Layout

The SNAPACK application uses the custom 16 MB partition layout established during the Known-Good Elecrow Display Baseline.

The custom `partitions.csv` is included in this directory.

The application partition begins at:

```
0x10000
```

and provides:

```
0xFF0000 bytes
```

for the application.

Arduino reports the resulting capacity as:

```
Maximum program storage space: 16711680 bytes
```

---

## Current Working Source

The current editable firmware source is:

```
snapack.ino
```

The current custom partition configuration is:

```
partitions.csv
```

These files represent the source/configuration state corresponding to this firmware checkpoint.

---

## Current Working Firmware Backup

The exported build files corresponding to this checkpoint are archived together in:

```
Current_Working_Firmware.zip
```

The archive contains the current source/configuration and exported build artifacts required to preserve this working firmware state.

Important files include:

```
snapack.ino
partitions.csv
snapack.ino.bootloader.bin
snapack.ino.partitions.bin
snapack.ino.bin
snapack.ino.elf
snapack.ino.map
```

This archive is the saved **Current Working Firmware** checkpoint.

---

## Development Workflow

Current development workflow:

1. Edit `snapack.ino`.

2. Save the source file.

3. Open/reopen `snapack.ino` in Arduino IDE as necessary.

4. Run **Verify** in Arduino IDE.

5. Use:

   ```
   Sketch → Export Compiled Binary
   ```

6. Flash the exported binaries using esptool.

7. After a useful working checkpoint is reached, update the files in this directory and replace the Current Working Firmware archive.

---

## Flashing

### Development-Machine Note

On the development machine used for SNAPACK, Arduino IDE's conventional upload process has been unreliable during sustained transfer of the large application image.

Arduino IDE successfully:

* detects the ESP32-S3,
* enters the bootloader,
* begins flashing,
* and writes initial flash regions,

but sustained transfer of the large application image has previously failed.

The same general behavior occurred while reading the original 16 MB factory flash: stub-based esptool transfers failed, while a `--no-stub` transfer successfully read the complete flash.

Using esptool's ROM-loader path with:

```
--no-stub
```

has proven reliable on this development machine/display combination.

---

## Working Flash Command

The following command structure has successfully flashed SNAPACK firmware on the development system:

```bash
~/.local/bin/esptool --no-stub --chip esp32s3 --port /dev/ttyACM0 \
  write-flash --flash-mode dio --flash-freq 80m --flash-size 16MB \
  0x0000  /home/valued/Arduino/snapack/build/esp32.esp32.esp32s3/snapack.ino.bootloader.bin \
  0x8000  /home/valued/Arduino/snapack/build/esp32.esp32.esp32s3/snapack.ino.partitions.bin \
  0xe000  /home/valued/.arduino15/packages/esp32/hardware/esp32/2.0.14/tools/partitions/boot_app0.bin \
  0x10000 /home/valued/Arduino/snapack/build/esp32.esp32.esp32s3/snapack.ino.bin
```

---

## Purpose of This Directory

This directory is the **moving development checkpoint** for SNAPACK firmware.

When firmware reaches a useful working state, the current source, partition configuration, and exported build artifacts should be saved here before further development.

The separate **Known-Good Elecrow Display Baseline** remains the original proven recovery point and should not be overwritten by ongoing SNAPACK development.

