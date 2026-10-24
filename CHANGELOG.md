# Changelog

## v2.0.0 — 2026-10-24

### Added
- **Single file with a graphical interface.** The engine, signing and checks all live in `Win10-ISO-Updater.cmd`; long jobs run in the background with a live log and a DISM / download progress bar.
- **Signed NVIDIA / modded drivers** page: re-signs edited INF packages (NVCleanstall) with a self-signed certificate, downloads `Inf2Cat` / `signtool` automatically, and installs them during setup through `$OEM$` + `SetupComplete-drivers.cmd`.
- **`$OEM$` folder** support, merged with the signed drivers; your `SetupComplete.cmd` gets a call to the driver script in the ISO copy.
- **Install check** page for the answer file, `$OEM$` scripts and drivers, with one-click fixes, a saved / undoable fixed answer file, and a check before every build.
- **OEM-key fallback:** the driver script can also run from the `specialize` pass, because Windows skips `SetupComplete.cmd` on Home/Pro with an OEM key. It runs only once.
- Option to install the driver folders in your `$OEM$\$1` with `pnputil`.
- `oscdimg` is downloaded automatically when the ISO is built (Microsoft symbol server, SHA-256 checked, ADK fallback).

### Changed
- Replaces the v1 menu `.cmd` + `.ps1` pair and the separate `Sign-Drivers.cmd`.

## v1.1.0
- Import a drivers folder (`Drivers-Backup` from `Drivers.cmd`, another PC, a vendor pack), with INF parsing and architecture filtering.

## v1.0.0
- Console menu: unpack, editions, Microsoft Update Catalog downloads, driver slipstreaming from this PC, `autounattend.xml`, DISM servicing, BIOS + UEFI ISO build.
