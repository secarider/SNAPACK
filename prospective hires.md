
PROSPECTIVE HIRES

SNAPACK remains an active hardware and firmware development project.

This file is maintained as an open invitation to embedded developers,
engineers, and other technically experienced people who may be interested
in reviewing the project, contributing expertise, or discussing possible
paid development work.

The project has progressed substantially, but outside technical review
remains welcome. A fresh set of experienced eyes can identify weaknesses,
suggest better approaches, or provide expertise in areas where additional
specialization would be valuable.

PROJECT STATUS

SNAPACK is a high-current battery system built around an ESP32-S3
controller and display.

The project combines:

• Battery cell and system-voltage monitoring

• Bidirectional current measurement

• Temperature monitoring

• Contactor and output control

• Hardware-assisted fault response

• Charging and operating-state supervision

• Persistent configuration and calibration

• Touchscreen / rotary user interface

• Diagnostic and service functions

Development has included both the physical hardware and functioning
firmware on the actual ESP32-S3 display hardware.

The repository documentation is actively maintained as the hardware
architecture is refined. Experimental arrangements are progressively
being separated from decisions intended for the permanent system.

CURRENT FIRMWARE OBJECTIVE

The immediate objective is the permanent Tier 1 firmware architecture.

Tier 1 deliberately emphasizes function and diagnostics over elaborate
presentation.

The purpose is to establish a reliable production-quality foundation for:

• Hardware initialization

• Sensor acquisition

• Measurement processing

• Fault detection and response

• Contactor and hardware-control logic

• Configuration and calibration

• Persistent storage

• Diagnostics

• Display and operator interaction

The simple Tier 1 interface should not be interpreted as disposable
prototype software.

Later graphical development is intended to build upon the same underlying
measurement, safety, storage, diagnostic, and hardware-control
architecture rather than replacing it.

Presentation and application logic should remain sufficiently separated
that the LVGL/SquareLine interface can evolve without requiring the
authoritative machine-control system to be rewritten.

RELEVANT EXPERIENCE

Experience in any combination of the following areas may be useful:

• ESP32-S3 embedded development

• C / C++

• Arduino or PlatformIO

• LVGL

• SquareLine Studio

• I2C hardware and firmware

• ADS1115 ADC integration

• 1-Wire devices and interfaces

• Battery monitoring systems

• Current and voltage measurement

• Contactors, relays, and hardware interlocks

• Embedded fault detection and fail-safe design

• Nonvolatile configuration and calibration storage

• Hardware/firmware integration and debugging

Experience with every item is not required.

TECHNICAL REVIEW IS WELCOME

Interest does not need to begin with a proposal to take over the entire
firmware project.

Constructive technical review is welcome.

If you see an architectural problem, questionable assumption, overlooked
failure mode, cleaner implementation, or a better way to accomplish
something documented in this repository, that information is useful.

Likewise, developers interested in a particular portion of the system are
welcome to make contact even if they are not interested in undertaking
the complete project.

The purpose of maintaining detailed project documentation is not only to
support development, but also to make meaningful independent technical
review possible.

POSSIBLE DEVELOPMENT WORK

I remain interested in working with qualified embedded developers where
additional experience or development capacity would benefit the project.

The existing project should be reviewed before proposing major
architectural changes. A considerable amount of hardware testing and
incremental development has already occurred, and many decisions recorded
in the documentation are the result of physical testing rather than
theoretical design alone.

At the same time, documented decisions are not immune from technical
challenge. If there is a demonstrably better or safer solution, it should
be discussed.

The objective is a dependable finished system, not preservation of a
particular implementation merely because it was developed first.

CONTACT

Questions, technical observations, development proposals, and expressions
of interest are welcome.

Contact:

[secarider@protonmail.com](mailto:secarider@protonmail.com)

Please include enough information about your relevant experience or
technical observation to provide context for the discussion.

SNAPACK
