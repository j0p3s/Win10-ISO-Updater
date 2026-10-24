# Win10 ISO Updater

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
   - builds a new catalog for **every modified package only** and signs and verifies it
3. When the ISO is built, the package goes to `$OEM$\$1\Drivers\NVIDIA` together with the public `DriverSigning.cer`, and `SetupComplete-drivers.cmd` is generated. During Windows setup that script:
   - trusts the certificate (`Trusted Root` + `Trusted Publishers`)
   - runs `pnputil /add-driver ... /subdirs /install`
   - optionally deletes the driver copy from `C:\Drivers`

If your `$OEM$` already has a `SetupComplete.cmd`, a `call "%~dp0SetupComplete-drivers.cmd"` line is added to the copy that goes into the ISO. Your own file is not changed.

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

**`$OEM$` folder**
- folders that Windows 10 ignores (anything other than `$$` and `$1`)
- `autounattend.xml` inside `$1` (never read by Setup) → **fix**: use it as the answer file
- `unattend.xml` in `$$\Panther`, `SetupComplete.cmd` in the wrong place
- scripts saved as UTF-16 / with a BOM / with LF line endings
- `pause`, `set /p`, `choice` or restarts in scripts that run hidden during setup
- driver folders whose INF was edited or is unsigned (Windows will refuse them)
- driver folders that nothing installs → **fix**: install them with `pnputil`

**Drivers and setup scripts**
- slipstreamed drivers that are not validly signed (for example, a modded NVIDIA driver exported from this PC) → **fix**: remove them
- signed packages made with a different certificate or missing from the work folder
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
| ISO won't boot with Secure Boot on (Boot2023 option) | The firmware doesn't trust *Windows UEFI CA 2023* yet — turn the option off or update the firmware's Secure Boot DB |
| install.wim larger than 4 GB for a FAT32 USB | Use Rufus, or turn on *Split install.wim* on page 7 |

---

## Building from source

The `.cmd` is assembled from the files in [`src/`](src):

```
python src/build.py
```

`src/engine_v1.ps1` is the original engine (catalog, DISM servicing, ISO build). `build.py` takes the parts it needs from it and adds the GUI, signing and install check parts. The output is ASCII with CRLF line endings, which `cmd.exe` requires.

---

## Related

- [autounattended-generator](https://github.com/j0p3s/autounattended-generator) — make the `autounattend.xml`
- [Update-SecureBootCert](https://github.com/j0p3s/Update-SecureBootCert) — Secure Boot certificate updater
- [Build-exe_from_bat_cmd_or_ps1](https://github.com/j0p3s/Build-exe_from_bat_cmd_or_ps1) — turn this .cmd into an .exe

## Disclaimer

Use at your own risk. Answer files can wipe disks — read the Install check findings before booting the ISO on a PC with data you care about. Windows, DISM and NVIDIA are trademarks of their respective owners. This project is not affiliated with Microsoft or NVIDIA.

## License

[MIT](LICENSE)
