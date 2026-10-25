# Changelog

## v2.1.1 — 2026-10-25

### Fixed
- **Clean up left the copied drivers, the answer file copy, the install check results, the logs and `state.json` behind.** New choices: *Copied drivers*, *Answer file copy and install check results*, *Logs*, and *Everything — empty the work folder and start from scratch*. "Everything" deletes only what the tool itself creates there (anything else in that folder is left alone) and resets the state; settings and the signing certificate next to the `.cmd` are kept.

## v2.1.0 — 2026-10-25

### Added — faster slipstream (page 7, *Speed*)
- **boot.wim is updated at the same time as install.wim** (on by default). It runs in a second background worker with its own DISM log (`dism-boot.log`); its Activity log follows after install.wim and is merged into `engine.log`, and the status line shows both jobs. If the worker can't start, boot.wim is updated afterwards as before; an error in either job stops both and discards the mounts.
- **Windows Defender can skip the work folder while a job runs** (off by default). Added for unpack, download, sign, slipstream and build only, removed at the end, and cleaned up at the next start after a crash. An exclusion you set yourself is not touched.
- **Leave boot.wim index 1 (Windows PE for WDS) as it is** (off by default) - USB / DVD setup boots index 2.

### Changed
- Storage / network drivers go into WinRE and boot.wim with one DISM call (one driver set) instead of one call per driver.
- DISM servicing uses a scratch folder inside the work folder instead of `%TEMP%`.
- The slipstream code moved from the v1 engine into `src/35_engine_service.ps1`.

## v2.0.8 — 2026-10-25

### Changed
- oscdimg's "N% complete" lines drive the progress bar instead of filling the Activity log with 100 lines.

## v2.0.7 — 2026-10-25

### Fixed
- **Build ISO stopped with "The path is not of a legal form"** when the *Output ISO* box held a name without a folder (or a folder). The box now accepts a full path, a folder (the default file name is used) or a bare name (saved in the output folder); `.iso` is added, and invalid input gets a clear message. The log shows the output path before oscdimg runs.

## v2.0.6 — 2026-10-25

### Added
- **Faster signing option: "Only keep the INF files for this PC's hardware"** (page 5, off by default). NVIDIA's `Display.Driver` has about 40 INF files, one per laptop / desktop maker, and Inf2Cat checks each of them against the whole ~1 GB package. With this on, only the INF files that list a device of this PC are kept in the work copy and signed, so it takes minutes instead of up to an hour.
  - INF files without device IDs and INF files a kept one includes stay; a folder where nothing matches is kept whole.
  - Use it only when the ISO is for this PC. The Install check notes such packages and warns when a script runs their `setup.exe`.

### Changed
- **Live Inf2Cat status.** The status line shows the folder (n of m), the running time and what Inf2Cat is doing. The log shows each folder's INF count and how long Inf2Cat took, explains the wait for big folders, and `engine.log` gets a "still running" line every 5 minutes.
- The status line no longer keeps showing "checking INF 47" after the signature check.

## v2.0.5 — 2026-10-24

### Changed — Install check
- **Fewer false alarms.**
  - Paths inside Windows' own folders (`Panther`, `Temp`, `Sysnative`, `SysArm32`, `System32`, ...) and paths built from variables are no longer reported as missing from `$OEM$`.
  - A script called with parameters (`call "%~dp0Tool.cmd" /switch`) is a menu script running unattended, so its prompts are reported as Info instead of one warning per line.
- **Scripts embedded in the answer file are checked.** These are `<Extensions><File path="...">` files, as written by the autounattend generator. The files they create count as existing, and their PowerShell is checked for `Read-Host` / restarts and for the paths they use.
- **New conflict check.** It warns when something uses a file inside a signed driver package (for example a first-boot script running `C:\Drivers\NVIDIA\setup.exe`) while the driver copy is deleted after `pnputil` installs it. The fix keeps the copy.

## v2.0.4 — 2026-10-24

### Fixed
- **Install check fixes were never applied.** Windows PowerShell 5.1 reads a JSON array as one object, so the check list showed one row of `System.Object[]`. "Apply fixes" sent a single meaningless fix, and the saved answer file kept every problem. The results are now unrolled, so each finding is its own row and every fix is applied.

### Changed
- Script findings are grouped: one finding per script for prompts (`pause` / `set /p` / `choice`), restarts, fixed drive letters and missing files, with the line numbers, instead of one finding per line.

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
