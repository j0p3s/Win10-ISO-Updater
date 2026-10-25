# Win10 ISO Updater

![version](https://img.shields.io/badge/version-2.0.6-2F9BFF) ![platform](https://img.shields.io/badge/Windows-10%20%7C%2011-8B5CF6) ![license](https://img.shields.io/badge/license-MIT-3DDC97)

**One file. Double-click. Get a fully updated Windows 10 ISO with your drivers, your signed NVIDIA mod, your answer file and your `$OEM$` folder baked in.**

`Win10-ISO-Updater.cmd` is a single-file tool with a dark graphical interface that:

1. **Unpacks a Windows 10 ISO** and detects its build, editions, language and architecture
2. **Downloads every update it needs** from the Microsoft Update Catalog (cumulative update, servicing stack, Safe OS and Setup Dynamic Updates, .NET)
3. **Slipstreams drivers** from this PC or from a `Drivers-Backup` folder (storage and network drivers also go into `boot.wim` and WinRE)
4. **Re-signs modded drivers** (NVCleanstall hardware-ID mods, edited INF files) with your own certificate and installs them during setup
5. **Adds your `autounattend.xml` and `$OEM$` folder**
6. **Checks everything** before the build: answer file, `$OEM$` scripts and drivers, with one-click fixes
7. **Builds a bootable BIOS + UEFI ISO**

Missing tools (`oscdimg`, `Inf2Cat`, `signtool`) are downloaded automatically from Microsoft and verified.

---

## Quick start

1. Download **[`Win10-ISO-Updater.cmd`](Win10-ISO-Updater.cmd)** and put it in a folder, for example `C:\W10U-Tool`.
2. Double-click it and accept the administrator prompt.
3. On page **1**, pick your Windows 10 ISO. Set up the other pages as you like.
4. Press **Run everything**.

That's it. The new ISO lands in `C:\W10U\output` (the work folder can be changed under *Options*).

The console line at start shows the version (`Starting Win10 ISO Updater v2.0.6 ...`), then the console hides and the window opens.

**Updating:** replace `Win10-ISO-Updater.cmd` with the new one. Your settings, the `signing` folder and the work folder (unpacked media, updates, drivers) are kept — the tool picks up where you left off.

> Requirements: Windows 10 or 11, Windows PowerShell 5.1 (built in), administrator rights, an NTFS drive with about 30 GB free, and an internet connection.

---

## The pages

| # | Page | What it does |
|---|------|--------------|
| 1 | **Source ISO** | Copies the ISO into the work folder and shows its build, editions, language and architecture |
| 2 | **Editions** | Tick the editions to update. Unticked ones can be left out, which makes the ISO smaller and the build faster |
| 3 | **Windows updates** | Finds and downloads the newest LCU, SSU, Safe OS DU, Setup DU, .NET 4.8.1 and .NET CU (SHA-1 checked). Optional .NET 3.5 and `/ResetBase` |
| 4 | **Drivers** | *Add drivers from this PC* (`Export-WindowsDriver`) or *Import a drivers folder* (for example `Drivers-Backup` made by `Drivers.cmd`). All subfolders are scanned, and drivers for the wrong architecture are left out |
| 5 | **Signed NVIDIA / modded** | Re-signs edited driver packages so Windows accepts them (see below) |
| 6 | **Answer file + `$OEM$`** | Your `autounattend.xml` (from [autounattended-generator](https://github.com/j0p3s/autounattended-generator)) and your `$OEM$` folder |
| ✓ | **Install check** | Finds what would break or stall a clean install, and fixes it |
| 7 | **Slipstream + build ISO** | Services WinRE, `install.wim` and `boot.wim`, then writes the ISO. Options: no "press any key", Windows UEFI CA 2023 boot manager, split `install.wim` for FAT32 |

---

## Modded drivers (NVIDIA / NVCleanstall)

Editing a driver's INF (for example, adding the hardware ID of a GPU that NVIDIA doesn't officially support) breaks its catalog signature. 64-bit Windows then refuses to install it.

On page **5**:

1. Pick the folder NVCleanstall extracted. Every subfolder is scanned.
2. Press **Sign and add to the ISO**. The tool then:
   - copies the package into the work folder (your original is not touched)
   - extracts only `Inf2Cat` + `signtool` from Microsoft's NuGet packages (Windows SDK build tools / Windows Driver Kit) — nothing is installed
   - creates a **self-signed code-signing certificate** the first time (you choose the password for its backup `DriverSigning.pfx`)
   - builds a new catalog for **every modified package only** and signs and verifies it. "Modified" covers an edited INF and a catalog signed with a certificate Windows doesn't trust (NVCleanstall signs its packages with its own).
   - shows what `Inf2Cat` is doing and for how long in the status line, and logs how long each folder took
3. When the ISO is built, the package goes to `$OEM$\$1\Drivers\NVIDIA` together with the public `DriverSigning.cer`, and `SetupComplete-drivers.cmd` is generated. During Windows setup that script:
   - trusts the certificate (`Trusted Root` + `Trusted Publishers`)
   - runs `pnputil /add-driver ... /subdirs /install`
   - optionally deletes the driver copy from `C:\Drivers` (turn this off if a script of yours still needs the files, for example `C:\Drivers\NVIDIA\setup.exe`; the Install check spots that)
   - runs only once, even when it is also started from the answer file's `specialize` pass (see Install check)

If your `$OEM$` already has a `SetupComplete.cmd`, a `call "%~dp0SetupComplete-drivers.cmd"` line is added to the copy that goes into the ISO. Your own file is not changed.

### Why signing NVIDIA takes so long, and the faster option

NVIDIA's `Display.Driver` folder has one INF file per laptop and desktop maker (about 40), all pointing at the same ~1 GB of files. `Inf2Cat` checks every one of them against the whole package, so a full NVIDIA package can take **up to an hour**. The status line keeps counting while it works; `engine.log` gets a "still running" line every 5 minutes.

**Faster: only keep the INF files for this PC's hardware** (page 5, off by default) reads the hardware IDs of this PC and, in folders with several INF files, keeps only the ones that list a device of this PC — for example the INF you added your GPU's ID to with NVCleanstall. The others are removed from the work copy (the original folder is not touched), so signing takes minutes.
- INF files without device IDs, and INF files that a kept one includes (`Include=`), stay.
- A folder where no INF matches this PC is kept whole.
- Use it only when the ISO is for **this PC**: the driver then installs only on matching hardware.
- NVIDIA's own `setup.exe` may refuse to run from a trimmed copy; `pnputil` installs the driver anyway. The Install check warns when a script of yours runs that `setup.exe`.

The kernel driver files keep NVIDIA's own signature. Only the catalog is yours, so **Secure Boot can stay on**.

> ⚠️ **Keep `signing\DriverSigning.pfx` private and backed up.** Anyone with it can sign drivers that your PCs will trust. Only the public `.cer` goes into the ISO. It is excluded by [`.gitignore`](.gitignore) — never upload it.

> ℹ️ The NVIDIA Control Panel in DCH drivers is a separate Store app and is not installed this way.

---

## Install check

The **Install check** page (it also runs automatically before every build) compares your answer file, `$OEM$` folder and drivers with the ISO that is being built.

**Answer file (`autounattend.xml`)**
- wrong `processorArchitecture` (Setup silently ignores those components) → **fix**
- edition index that changed because only some editions were kept → **fix**
- edition name or generic product key that isn't in the ISO
- setup / display language that isn't in the ISO → **fix**
- invalid computer name (more than 15 characters, `_`, only digits) → **fix** (`*`)
- time zone that doesn't exist → **fix** (this PC's)
- reserved or invalid account names, account equal to the computer name, hidden account screen with no account
- duplicate or missing `<Order>` numbers → **fix**
- `Extend` + `Size` on the same partition → **fix**, `InstallTo` + `InstallToAvailablePartition` → **fix**
- disk wipe warning, GPT/UEFI vs MBR/legacy boot hint, EFI partition size
- commands that use files missing from `$OEM$` or fixed drive letters (`D:\`)
- scripts the answer file writes itself (`<Extensions><File path="...">`, as made by the autounattend generator) count as existing, and their PowerShell is checked too

**`$OEM$` folder**
- folders that Windows 10 ignores (anything other than `$$` and `$1`)
- `autounattend.xml` inside `$1` (never read by Setup) → **fix**: use it as the answer file
- `unattend.xml` in `$$\Panther`, `SetupComplete.cmd` in the wrong place
- scripts saved as UTF-16 / with a BOM / with LF line endings
- `pause`, `set /p`, `choice` or restarts in scripts that run hidden during setup (one finding per script, with line numbers). A script called with parameters (`call "%~dp0Tool.cmd" /switch`) is treated as running unattended, so its menus are only noted
- files a script uses that won't exist — Windows' own folders (`System32`, `Sysnative`, `Panther`, `Temp`, `Program Files`, ...) and paths built from variables are not reported
- driver folders whose INF was edited, is unsigned or is signed with an untrusted certificate (Windows will refuse them)
- driver folders that nothing installs → **fix**: install them with `pnputil`

**Drivers and setup scripts**
- slipstreamed drivers that are not validly signed (for example, a modded NVIDIA driver exported from this PC) → **fix**: remove them
- signed packages made with a different certificate or missing from the work folder
- packages signed with *only the INF files for this PC* (noted), and a script that runs their `setup.exe` (warning)
- something that uses a file inside a signed package while the driver copy is deleted after installation → **fix**: keep the copy
- **SetupComplete.cmd is skipped by Windows on Home/Pro installs activated with an OEM key** (PCs sold with Windows keep the key in the firmware; the tool checks this PC too) → **fix**: the driver script also runs from the `specialize` pass of the answer file, and runs only once

Fixes only change the copies that go into the ISO. You can **save the fixed answer file** over your own, or **undo** the answer file fixes.

---

## Windows 10 updates and ESU

Microsoft blocks offline integration of the Windows 10 **ESU** updates (November 2025 and later). For 2004–22H2 and LTSC 2021 the default limit is **2025-10** (KB5066791, build 19045.6456). PCs enrolled in ESU get the newer updates from Windows Update after setup. The month can be changed on page 3.

Supported for automatic updates: **1607 / LTSB 2016, 1809 / LTSC 2019, 2004–22H2, LTSC 2021** (x64, x86, ARM64).
Any other Windows 10 / 11 image can still get drivers, signed packages, an answer file and `$OEM$`.

---

## Files the tool creates

| Path | Contents |
|------|----------|
| `tools\` (next to the .cmd) | Downloaded `oscdimg`, `Inf2Cat`, `signtool` — safe to delete |
| `signing\` (next to the .cmd) | `DriverSigning.pfx` (**private**) + `DriverSigning.cer` |
| `Win10-ISO-Updater.settings.json` | Your options |
| `C:\W10U\` (work folder) | Unpacked media, updates, drivers, signed copies, logs, output ISO |

Logs: `C:\W10U\logs\engine.log` and `dism.log`. During install, the driver script writes `C:\Windows\Temp\SetupComplete-drivers.log`.

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| "Mount folder is not empty" | *Options and clean up* → **Clean up now** |
| Cumulative update fails with an ESU-related error | Set the month on page 3 back to `2025-10` |
| Drivers didn't install after setup | Read `C:\Windows\Temp\SetupComplete-drivers.log`, and run the **Install check** (OEM-key fallback) |
| `Inf2Cat` "Signability test failed" | Delete `inf2cat.exe.manifest` next to `Inf2Cat.exe` and sign again |
| *Re-sign drivers* runs for a very long time on `Display.Driver` | Normal for a full NVIDIA package (up to an hour). Check that `Inf2Cat.exe` uses CPU in Task Manager → Details. Next time turn on *Only keep the INF files for this PC's hardware* |
| "Could not start: The property 'ItemsSource' cannot be found" / "SignTool Error: ... terminated in a root" / check list shows `System.Object[]` | Bugs of v2.0.0 – v2.0.3. Make sure the copy you start is the newest: the first console line shows the version |
| A line starting with `Interface error:` in the Activity log | Something in the window failed but the program kept running — please open an issue with that line and `C:\W10U\logs\engine.log` |
| The full Windows SDK / WDK got installed (v2.0.0) | Not needed any more — uninstall *Windows Software Development Kit* and *Windows Driver Kit* under Settings → Apps if you like |
| ISO won't boot with Secure Boot on (Boot2023 option) | The firmware doesn't trust *Windows UEFI CA 2023* yet — turn the option off or update the firmware's Secure Boot DB |
| install.wim larger than 4 GB for a FAT32 USB | Use Rufus, or turn on *Split install.wim* on page 7 |

---

## Building from source

The `.cmd` is assembled from the files in [`src/`](src):

```
python src/build.py
```

`src/engine_v1.ps1` is the original engine (catalog, DISM servicing, ISO build). `build.py` takes the parts it needs from it and adds the GUI, signing and install check parts. The output is ASCII with CRLF line endings, which `cmd.exe` requires.

| File | Part |
|------|------|
| `00_header.cmd` | batch launcher: elevation, starts the PowerShell part of the same file |
| `10_engine_head.ps1` | constants, log sink (every `Write-Host` goes to the Activity panel), Yes/No questions from the worker |
| `30_engine_tools.ps1` | console tools with live output and progress, oscdimg / Inf2Cat / signtool download |
| `31_engine_sign.ps1` | certificate, catalogs, re-signing, `$OEM$` assembly, `SetupComplete-drivers.cmd` |
| `33_engine_check.ps1`, `34_engine_check2.ps1` | install check and its fixes |
| `32_engine_jobs.ps1` | driver scan / import, answer file, run everything, job entry point for the background worker |
| `40_gui_xaml.ps1`, `45_gui_dialogs.ps1` | window, pages and dialogs (WPF XAML) |
| `50_gui.ps1`, `55_gui_main.ps1` | window logic, background worker, events |

### Tests

```
pwsh tests/run-tests.ps1
```

Six suites (about 165 checks) run the PowerShell part on Linux / macOS with PowerShell 7: catalog parsing, signing with stand-ins for `signtool` / `Inf2Cat` (an NVCleanstall-style untrusted catalog, live Inf2Cat status from a worker runspace, keeping only this PC's INF files), `$OEM$` assembly, every install check finding and fix, an answer file made by the autounattend generator (`tests/fixtures`, personal data removed), and the page refresh with Windows PowerShell 5.1's JSON behaviour simulated. DISM, WPF and real driver installs still need a Windows test run.

---

## Related

- [autounattended-generator](https://github.com/j0p3s/autounattended-generator) — make the `autounattend.xml`
- [Update-SecureBootCert](https://github.com/j0p3s/Update-SecureBootCert) — Secure Boot certificate updater
- [Build-exe_from_bat_cmd_or_ps1](https://github.com/j0p3s/Build-exe_from_bat_cmd_or_ps1) — turn this .cmd into an .exe

## Disclaimer

Use at your own risk. Answer files can wipe disks — read the Install check findings before booting the ISO on a PC with data you care about. Windows, DISM and NVIDIA are trademarks of their respective owners. This project is not affiliated with Microsoft or NVIDIA.

## License

[MIT](LICENSE)
