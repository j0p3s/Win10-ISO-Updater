# Changelog

## v2.0.3 — 2026-10-24

### Fixed
- **Re-signing stopped with "SignTool Error: A certificate chain processed, but terminated in a root"** on NVCleanstall packages. Their catalogs are signed with a certificate Windows doesn't trust. signtool reports that on stderr, and Windows PowerShell 5.1 turned it into a job-ending error. Console tools now run through a helper that captures stderr. Packages with an untrusted catalog are detected as "needs a new signature" and re-signed, and the install check reports them clearly.
- Page text inside the main area was nearly black on the dark background (the page container used the system text color); it now uses the theme color.

## v2.0.2 — 2026-10-24

### Fixed
- **"Could not start: The property 'ItemsSource' cannot be found"** once updates had been downloaded. A loop variable (`$u`) overwrote the window's control list (`$U`), because PowerShell variable names ignore case.
- When more than one NuGet package was tried, the tool name was overwritten by its path, so the second package was never searched.
- An error inside a button or a background refresh is now written to the Activity log instead of closing the program.

## v2.0.1 — 2026-10-24

### Fixed
- `Inf2Cat.exe` from the Windows Driver Kit NuGet package was rejected because it has no Authenticode signature of its own. That triggered a full Windows SDK + WDK install through winget. It is now accepted as part of Microsoft's package, and the winget fallback is gone: only the `Inf2Cat` and `signtool` folders are extracted, nothing is installed.
- Maximizing the window (button, double-click on the title bar, Win+Up, Aero Snap) no longer covers the taskbar and hides the Activity panel. The window now fills the work area of its monitor, and it never opens taller than the screen.
- Combined .NET cumulative updates are downloaded and applied once, not once per KB that shares the same files.
- curl's start-up spinner lines no longer clutter the log; the progress percentage is no longer rounded down.

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
