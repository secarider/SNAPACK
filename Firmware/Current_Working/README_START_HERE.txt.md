This package contains the complete SNAPACK Step90
Developer / Diagnostic firmware release set.

Step90 is the designated SNAPACK development baseline.

SOFTWARE OVERVIEW
-----------------

Step90 represents a functioning embedded monitoring,
diagnostic, event-management, and graphical operator
interface developed for the SNAPACK hardware platform.

The firmware is substantially more than a display
demonstration. Development through Step90 established
and tested the core software systems used to acquire,
interpret, display, and respond to SNAPACK sensor data.

Implemented systems include:

• Multi-channel ADS1115 analog data acquisition

• Five-cell battery voltage acquisition and individual
  cell-voltage calculation from cumulative measurements

• Bidirectional OTC Hall-effect current monitoring

• Current-sensor zeroing, filtering, and direction handling

• DS2484 / DS18B20 multi-point temperature acquisition

• Current, Cell Voltage, Thermal, and Thermal Differential
  event monitoring

• Configurable event thresholds and Settings editors

• Authoritative event ownership capable of overriding the
  ordinary user interface when monitored conditions require
  operator attention

• Automatic presentation of the Current warning/display
  during qualifying current events

• Dedicated Cell and Thermal warning behavior

• Event clearing and operator acknowledgment behavior

• Persistent settings using ESP32 nonvolatile storage

• Touchscreen and rotary-control user interface

• Multiple graphical monitoring and configuration screens

• Animated visual status and warning presentation

• Diagnostic instrumentation covering System, ADS, I2C,
  Cell, Thermal, Current, Event, Settings, UI, and Wi-Fi

• Serial, RAM-log, and Event-History diagnostic outputs

• Wi-Fi / NTP support when locally configured

The firmware also contains substantial graphical and
human-interface development for the 480 x 480 round
ESP32-S3 display. This includes monitoring screens,
settings interfaces, graphical gauges, warning
presentations, animated status elements, touch interaction,
rotary interaction, and screen-navigation behavior.

Step90 specifically exposes the diagnostic instrumentation
used during development. The same instrumentation can be
selectively enabled by category, while normal production-
style operation can leave it dormant.

The software distinguishes presentation data from
authoritative machine events. Diagnostic or placeholder
display data is not permitted to create an authoritative
Cell event, and missing sensor hardware is treated as
unavailable input rather than being silently converted
into a machine fault.

README_STEP90_DEVELOPER_DIAGNOSTIC.txt

    Detailed Step90 technical documentation.

    Describes the Step89H baseline inheritance,
    Developer / Diagnostic instrumentation,
    diagnostic build modes, Wi-Fi behavior,
    event-safety behavior, synthetic diagnostic data,
    known notes, and physical validation procedure.

snapack_ui_step90_developer_diagnostic.zip

    COMPLETE EDITABLE SOURCE PACKAGE.

    This is the "recipe."

    Developers and technical reviewers should begin here.

    It contains the SNAPACK Step90 firmware source and
    associated files required for inspection, modification,
    compilation, and continued development.

    No private SNAPACK Wi-Fi credentials are included.

    SNAPACK_LOCAL_ONLY_WIFI.example.h is supplied as the
    public configuration example.

bin_backup.zip

    COMPLETE EXPORTED FLASH IMAGE SET.

    This is the known-good prepared firmware image set.

    It contains the four ESP32-S3 binary artifacts,
    flash information, archive notes/status, and
    SHA-256 checksums.

    Flash layout recorded by the archive:

        0x0000   snapack.ino.bootloader.bin

        0x8000   snapack.ino.partitions.bin

        0xE000   boot_app0.bin

        0x10000  snapack.ino.bin

    The archive also records the applicable ESP32-S3
    flash configuration and integrity information.

Do not use the compiled BIN files as a substitute for
the firmware source.

Review and continued development should begin with:

    snapack_ui_step90_developer_diagnostic.zip

The BIN archive is provided as a known-good flashable
reference corresponding to the Step90 release.

The detailed Step90 README should be reviewed before
making architectural or behavioral changes.

This public release does NOT contain the SNAPACK owner's
private Wi-Fi credentials.

The source package provides:

    SNAPACK_LOCAL_ONLY_WIFI.example.h

A developer who requires Wi-Fi / NTP functionality may
copy or rename the example file to:

    SNAPACK_LOCAL_ONLY_WIFI.h

and enter local credentials.

Without a local credential file, Step90 is intended to
operate without waiting for an unavailable Wi-Fi
connection.

The private local Wi-Fi header must not be committed to
a public repository or redistributed with a public
firmware package.

The complete exported binary set is contained in:

    bin_backup.zip

Read the INFO, STATUS, NOTES, and checksum information
contained in that archive before flashing.

The four binaries form a coordinated firmware set.
They should be kept together with their recorded flash
addresses and release information.

Keep this START HERE file, the detailed Step90 README,
the source ZIP, and the BIN backup ZIP together.

Together they provide:

    1. Release identity and instructions

    2. Complete editable firmware source

    3. Credential-safe public configuration

    4. Complete exported flash artifacts

    5. Flash-layout information

    6. Archive status and notes

    7. Integrity checksums

This complete package should be preserved as the
publicly accessible SNAPACK Step90 Developer Edition
baseline.
