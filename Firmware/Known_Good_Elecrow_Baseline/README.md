# SNAPACK — Known-Good Elecrow Display Baseline

This directory contains the first known-good, physically tested SNAPACK firmware baseline for the Elecrow 2.1-inch round ESP32-S3 display.

This baseline was compiled, flashed to the physical display, booted successfully, and tested with the Elecrow demo interface functioning.

The firmware has also been modified from the original Elecrow demo: a persistent **SNAPACK** LVGL label is displayed at the top of the interface. The label remains visible while navigating the carousel and its submenu screens.

This provides a confirmed starting point for further SNAPACK display and firmware development.

---

## Hardware

Display:

- Elecrow CrowPanel 2.1-inch HMI
- Model: DHE03921D
- 480 × 480 round IPS display
- ESP32-S3
- 16 MB flash
- 8 MB PSRAM
- Rotary encoder
- Touchscreen

The ESP32-S3 was detected by esptool as:

- ESP32-S3 QFN56, revision v0.2
- 40 MHz crystal
- 8 MB embedded PSRAM
- 16 MB SPI flash
- USB Serial/JTAG

---

## Known-Good Build Environment

The following environment successfully compiles and runs this firmware on the physical display:

- ESP32 Arduino Core: **2.0.14**
- Board: **ESP32S3 Dev Module**
- Flash Size: **16 MB**
- PSRAM: **OPI PSRAM**
- LVGL: **8.3.6**
- GFX Library for Arduino: **1.3.1**

The Elecrow-provided library versions are being used as the known-good baseline rather than automatically updating libraries to newer releases.

Do not assume that newer library or ESP32 core versions are drop-in compatible with this baseline.

---

## Partition Layout

The Elecrow demo application is approximately 6.36 MB, which is larger than the standard Arduino ESP32-S3 application partitions.

A custom 16 MB partition layout is therefore used.

The custom `partitions.csv` is included in this directory.

The application partition begins at:

    0x10000

and provides:

    0xFF0000 bytes

for the application.

Arduino reports the resulting capacity as:

    Maximum program storage space: 16711680 bytes

The known-good build currently uses approximately:

    6360000 bytes (~38%)

of that application space.

---

## Development Workflow

The development workflow used for this known-good baseline is:

1. Edit `snapack.ino` using **Xed**.
2. Save the source file.
3. Open/reopen `snapack.ino` in Arduino IDE.
4. Run **Verify** in Arduino IDE.
5. Use:

       Sketch → Export Compiled Binary

6. Flash the exported binaries from a terminal using esptool.

Editing with Xed is only a development preference and is not required. Any suitable source editor may be used.

Arduino IDE is currently being used primarily for compilation and binary export.

---

## Exported Build Files

Arduino places the exported build output in a directory similar to:

    build/esp32.esp32.esp32s3/

The complete known-good exported build has been archived in:

    build/build.zip

The ZIP archive is used to keep all generated build files together and to avoid GitHub web-upload size limitations.

ZIP compression does not alter the contents of the binaries. Extracted files are identical to the files that were archived.

The important flash images include:

    snapack.ino.bootloader.bin
    snapack.ino.partitions.bin
    snapack.ino.bin

The ESP32 Arduino package also supplies:

    boot_app0.bin

---

## Flashing

### Important Development-Machine Note

On the development machine used to establish this baseline, Arduino IDE's conventional upload process was unreliable.

Arduino IDE successfully:

- detected the ESP32-S3,
- entered the bootloader,
- began flashing,
- and wrote initial flash regions,

but the connection repeatedly failed during sustained transfer of the large application image.

Reducing the Arduino upload speed did not resolve the problem.

Changing the physical USB path also did not resolve the problem.

The same general behavior had previously occurred while reading the original 16 MB factory flash: stub-based esptool transfers failed, while a `--no-stub` transfer successfully read the entire flash.

Using esptool's ROM-loader path with:

    --no-stub

has proven reliable on this development machine/display combination.

This may be specific to this host, USB environment, or individual display. Other development systems may work normally using Arduino IDE's standard Upload function.

---

## Known-Good Flash Command

The following command successfully flashes the exported firmware on the development system:

```bash
~/.local/bin/esptool --no-stub --chip esp32s3 --port /dev/ttyACM0 \
  write-flash --flash-mode dio --flash-freq 80m --flash-size 16MB \
  0x0000  /home/valued/Arduino/snapack/build/esp32.esp32.esp32s3/snapack.ino.bootloader.bin \
  0x8000  /home/valued/Arduino/snapack/build/esp32.esp32.esp32s3/snapack.ino.partitions.bin \
  0xe000  /home/valued/.arduino15/packages/esp32/hardware/esp32/2.0.14/tools/partitions/boot_app0.bin \
  0x10000 /home/valued/Arduino/snapack/build/esp32.esp32.esp32s3/snapack.ino.bin
