![SNAPACK Logo](images.jpeg)
File Photo
# SNAPACK

## Intelligent 12V / 16V LiFePO₄ Jump Pack Monitor

SNAPACK is a custom high-current LiFePO₄ jump pack built around an ESP32-S3 touchscreen controller. The project combines battery instrumentation, high-current contactor control, temperature monitoring, current monitoring, and a modern round touchscreen interface into a compact portable jump-start system.

The hardware design is substantially complete. This repository exists primarily to support firmware and user interface development.

---

## Project Status

* Hardware prototype assembled
* Electrical architecture defined
* Existing Elecrow ESP32-S3 demonstration project
* Hardware Manifest complete
* Software Manifest complete
* Firmware implementation in progress

This is **not** a project starting from a blank sheet of paper. The hardware exists, the system architecture has been designed, and the expected firmware behavior has been documented.

---

## Development Platform

The intended firmware platform is:

* ESP32-S3
* Arduino Framework
* PlatformIO
* LVGL
* SquareLine Studio
* Elecrow 480×480 Round Display

The existing Elecrow demonstration project is intended to serve as the starting point rather than creating an entirely new user interface.

---

## Repository Contents

### Hardware_Manifest.txt

The Hardware Manifest is the authoritative engineering reference for:

* electrical architecture
* wiring
* pin assignments
* sensors
* contactors
* power supplies
* protection
* signal routing
* connector assignments

If hardware documentation and source code ever disagree, the Hardware Manifest is considered authoritative.

---

### Software_Manifest.txt

The Software Manifest defines the intended firmware behavior, including:

* display layout
* user interface
* monitoring screens
* temperature logic
* current monitoring
* battery resistance monitoring
* safety behavior
* configuration settings
* event logging
* lifetime statistics

Application behavior should follow the Software Manifest unless an engineering issue requires discussion.

---

## Design Philosophy

The project intentionally separates engineering responsibilities.

* Hardware design is documented in the Hardware Manifest.
* Firmware behavior is documented in the Software Manifest.
* SquareLine is used for interface generation.
* Application logic should remain outside SquareLine-generated files whenever practical.

This separation keeps the user interface maintainable while allowing application logic to evolve independently.

---

## Current Firmware Goals

The current implementation focuses on:

* Pack voltage monitoring
* Output current monitoring
* Five temperature sensors
* Battery mode detection (12V / 16V)
* Temperature fault detection
* Peak current recording
* Lifetime statistics
* Relay control for defined fault conditions
* Simple, readable operator interface

The initial goal is a functional diagnostic interface for hardware validation before refinement into a polished production interface.

---

## Contributing

Contributors familiar with the following technologies are especially welcome:

* ESP32-S3
* LVGL
* SquareLine Studio
* PlatformIO
* Arduino
* Embedded C++

Please keep application logic independent from generated UI files whenever practical.

---

## Project Goal

The display exists to answer one simple question:

> **"Is everything OK?"**

If the answer is yes, the interface should remain simple and unobtrusive.

If the answer is no, the display should immediately identify what requires attention.

---

## Project State

This repository documents an actively developed hardware project.

The engineering documentation is considered substantially complete, while firmware implementation continues as hardware testing progresses.
