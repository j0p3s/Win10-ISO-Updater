# Changelog

## v4.1.0 — 2026-10-30

Faster slipstream when several editions are ticked, and the time of every step at the end of the log.

**Upgrading from 4.0:** download `Windows-ISO-updater-GUI_v4.1.0.cmd` and delete the old `.cmd`. Settings, the `signing` folder and the work folder are kept.

### Added
- **Editions at the same time** (page 7, *Speed*). DISM can't use more than one process for one image, but several editions can be updated side by side:
  - each ticked edition is staged into a WIM file of its own and updated in a background job, with its own mount folder (`mnt\osN`), scratch folder and DISM / engine logs;
  - automatic: 2 at once on 4+ processor cores, 3 on 8+; or set 1–4 (1 = one after the other, as before);
  - each one needs about 25 GB free on the work drive; with less, fewer run at once and the log says why;
  - WinRE is updated once, from the first edition, as soon as that edition is mounted. Every edition waits for it just before it is saved;
  - the new `install.wim` keeps the original edition order, and editions that are not updated are copied as they are. It is written while the remaining editions are still being updated;
  - each edition's log follows in the Activity panel when it finishes. If one fails, the others are stopped, the mounts are discarded and the unpacked media stays as it was;
  - if no background worker can start, the editions are updated one after the other, with a warning.
- **Time per step** at the end of the slipstream log:
  - for every edition: stage, mount, drivers, servicing stack, cumulative update, enablement package, cleanup, .NET, waiting for WinRE, save, export;
  - WinRE and `boot.wim` (per index), the media folder, and the total.

### Fixed
- The storage / network driver set for WinRE and `boot.wim` counted one driver when there were none (no effect on DISM).

### Code and tests
- The updates of one mounted edition are one function (`Add-EditionUpdates`), used by the main job and by the edition jobs.
- `tests/service.tests.ps1` (67 checks, 20 new), against the stand-in `dism`:
  - how many editions run at once (automatic, setting, editions ticked, free space);
  - 3 editions with 2 at once: at most 2 mounted together, each staged into its own WIM, the new `install.wim` in the original order with the unticked edition, own logs and scratch folders;
  - WinRE updated once before any edition is saved and copied into all three;
  - the time-per-step table;
  - faster than one after the other;
  - a failing edition (the others stopped, media unchanged), and no background worker (one after the other).

### README
- *Speed*: the new option, the time-per-step table; troubleshooting row for the free-space warning.

## v4.0.0 — 2026-10-30

The signing changes of [NVIDIA Modded Drivers Signer](https://github.com/j0p3s/nvidia-modded-drivers-signer) 2.3.0, and a choice of the engine that builds the catalogs. A new major version because drivers are now signed by a different engine by default.

**Upgrading from 3.x:** download `Windows-ISO-updater-GUI_v4.0.0.cmd` and delete the old `.cmd`. Settings, the `signing` folder and the work folder are kept. **Signing now uses MakeCat by default**; choose *Inf2Cat* on page 5 for the old behaviour. Packages you already signed stay as they are.

### Added
- **Engine** buttons on page 5 (*Signed NVIDIA / modded*), saved as `SignEngine` in the settings file:
  - **MakeCat** (default): `makecat.exe` and a generated `.cdf` build **one catalog per driver folder** (`<folder>_w10u.cat`) with the SHA-256 hash of the INF files that need a new signature and of every file of the folder. Each file is hashed once — about 20 s for NVIDIA's 3 GB `Display.Driver`, where Inf2Cat can take up to an hour. `makecat.exe` comes from an installed Windows Kit or from Microsoft's NuGet packages (SDK build tools, then WDK).
  - **libwdi-style** (experimental): the same folder catalog, built with Windows' CryptCAT API (`wintrust.dll`) from a C# class compiled when needed, the way libwdi does it. Nothing to download.
  - **generate-cat-file (WSL)** (experimental): LINBIT's tool, downloaded as source from GitHub (pinned commit, SHA-256 checked) and built inside WSL.
  - **Inf2Cat**: Microsoft's standard tool, as before (isolated copies, several runs at the same time, time estimate).
  - A note under the buttons says what the chosen engine does and what it needs.
- **Every file of the folder goes into the catalog**, also the ones an INF copies as a whole directory and doesn't list in `[SourceDisksFiles]` (`ngx-builtins`, `NvCamera`). Windows checks every file it copies, and one missing hash makes it refuse the driver.
- **Compressed files** (`nvngx_dlssd.dl_`, while the INF names `nvngx_dlssd.dll`) are expanded with `expand.exe` into a temporary folder and hashed under the name the INF uses, because Windows checks the expanded file. The compressed file is hashed too.
- **Inf2Cat is the fallback**: when the engine isn't available (no `makecat.exe`, no WSL) or can't build a folder's catalog, Inf2Cat catalogues that folder in the same run. Inf2Cat is downloaded only then.
- After signing, every INF is checked against its new catalog with `signtool verify /pa /c`; a mismatch with a folder engine is reported with the hint to sign again with Inf2Cat.
- The log lists what went into each catalog (INF files, listed files, other files of the folder, compressed files) and warns about files an INF copies that are not in the folder.
- The list of signed packages has an **Engine** column. The *Tools* page shows `makecat.exe`.

### Changed
- *Inf2Cat runs at the same time* is now *Catalog runs at the same time*: MakeCat runs up to 4 folders at once.
- `tools\` holds `makecat.exe` when the MakeCat engine is used; `Inf2Cat.exe` is downloaded only when Inf2Cat signs.

### Code and tests
- New `src/39_engine_catalogs.ps1` with the engines, ported from the signer: INF `[SourceDisksFiles]` parsing with compressed files, catalog members, the `.cdf`, the CryptCAT class, the WSL build and run.
- The Inf2Cat process queue is now a general tool queue (`Invoke-ToolQueue`, with a working folder per run) that MakeCat uses too.
- New `tests/sign-engines.tests.ps1` (52 checks) with stand-ins for `makecat`, `expand.exe` and `wsl.exe`: catalog members and the `.cdf`, MakeCat end to end (only the edited INF moves to the folder catalog, the shared WHQL catalog stays valid), the fallback to Inf2Cat, libwdi-style and generate-cat-file runs, the CryptCAT source compiling, the engine setting and buttons.

### README
- New **Signing engines** section; troubleshooting, files, privacy and legal notice (generate-cat-file GPL-2.0, libwdi-style) updated.

## v3.6.0 — 2026-10-30

The changes listed under 4.0.0, published for a few minutes as 3.6.0 before they were numbered 4.0.0. Same code; use 4.0.0.

## v3.5.1 — 2026-10-30

Fix for 3.5.0, which did not open on Windows.

**Upgrading from 3.5.0:** download `Windows-ISO-updater-GUI_v3.5.1.cmd` and delete `Windows-ISO-updater-GUI_v3.5.0.cmd`. Settings, the `signing` folder and the work folder are kept.

### Fixed
- **3.5.0 stopped at start with "Windows ISO Updater could not start: '#FF0B0E14' is not a valid value for property 'Background'".** The theme colors were stored in the window's resources as PowerShell's wrapper object instead of the brush itself. Windows PowerShell 5.1 keeps that wrapper when an object goes straight into a dictionary, and WPF can't use it as a color. Every theme resource now holds the brush itself, so the window opens again in the dark and the light theme.

### Code and tests
- New `Set-Resource` helper: the only way resources are stored, always as the .NET object itself.
- `tests/theme.tests.ps1` shows the wrapper problem with a plain dictionary, checks that `Set-Resource` stores the object itself, and fails if any code assigns a resource directly.

### README
- New **Changelog** section with a short summary of every version and a link to this file.

## v3.5.0 — 2026-10-29

Display and accessibility options in the top right corner: a dark / light theme, the text size and the font.

**Upgrading from 3.4:** download `Windows-ISO-updater-GUI_v3.5.0.cmd` and delete the old `.cmd`. Settings, the `signing` folder and the work folder are kept. The window starts dark at 100 %, as before.

### Added
- **Theme switch** (sun / moon, top right, next to minimize): dark or light, at once, no restart.
- **Display and accessibility panel** (accessibility icon, top right) with:
  - **Theme:** *Dark*, *Light*, or *Like Windows*, which follows the app mode in Windows' color settings.
  - **Text size:** 100 %, 115 %, 130 % or 150 %. It zooms the whole window, so text, buttons and lists grow together. The sidebar scrolls when the larger size doesn't fit.
  - **Font:** Segoe UI, Verdana, Tahoma or Arial. Verdana and Tahoma have wider, more distinct letters. The log keeps Consolas, so its columns stay aligned.
- **Keyboard:** Ctrl + plus / Ctrl + minus / Ctrl + 0, or Ctrl + mouse wheel, change the text size anywhere in the window. Esc closes the panel.
- The choices are saved in the settings file (`UiTheme`, `UiZoom`, `UiFont`) and used at the next start. The driver picker and the certificate password dialog follow them too.
- The title bar buttons (theme, display, minimize, maximize, close) have names for screen readers.
- **Light theme:**
  - every text color has at least 4.5:1 contrast on its background (WCAG AA);
  - the log keeps its colors (green OK, yellow warning, red error) in darker shades;
  - the text cursor in input boxes is dark in the light theme (it was white).

### Code and tests
- The XAML stays written in the dark colors. When a window is loaded, every color of a brush becomes a theme resource (`T_<hex>`), and switching the theme swaps those resources. Brushes made in code go through `New-Brush`, which maps them too, and the log lines are recolored.
- New suite `tests/theme.tests.ps1` checks:
  - that the three windows are well-formed XAML after the conversion, with no fixed brush color left;
  - that every color used, in the XAML and in code, has a light color;
  - the 4.5:1 contrast of all text / background pairs in the light theme;
  - the theme, text size and font settings;
  - the panel state and the title bar buttons.
- In total there are 12 suites with about 375 checks.

## v3.4.0 — 2026-10-28

The program is now **Windows ISO Updater**: the file is called `Windows-ISO-updater-GUI_vX.X.X.cmd` and carries its version in the name. Plus a round of fixes found in a code review.

**Upgrading from 3.3:** download `Windows-ISO-updater-GUI_v3.4.0.cmd`, put it in the same folder and delete the old `Win10-ISO-Updater.cmd`. Your options are carried over (`Win10-ISO-Updater.settings.json` is read once and saved as `Windows-ISO-Updater.settings.json`), and the `signing` folder and the work folder are kept. The GitHub repository is now `j0p3s/Windows-ISO-Updater`.

### Changed
- **New file name**: `Windows-ISO-updater-GUI_vX.X.X.cmd`. The version is read from one place (`$Script:AppVersion` in `src/10_engine_head.ps1`); `build.py` puts it in the file name, the header, the start line and the version label in the window, and removes older builds.
- The release workflow attaches `Windows-ISO-updater-GUI_vX.Y.Z.cmd` and its `.sha256`; the `tests` workflow checks that the committed build is the build of `src/`.
- Names and titles say *Windows ISO Updater* everywhere (window, message boxes, log, ISO label fallback `WINDOWS_CUSTOM`). The settings file name no longer changes with the version.
- The *Save as* box of the Build page suggests `Win10_custom.iso` or `Win11_custom.iso` after the Windows version of the unpacked ISO.

### Fixed
- **Your own `SetupComplete.cmd` kept byte for byte.** Adding the driver call used to rewrite the file as ASCII, so accented characters in it became `?` and a UTF-8 BOM was dropped. Now only the `call` line is inserted; encoding and BOM stay.
- **Accents in a driver package name** (for example a folder called `Gráficos`) no longer end up as `?` in `SetupComplete-drivers.cmd`: names are transliterated to plain ASCII. An `$OEM$` driver folder with non-ASCII characters is skipped with a note in the log, as it cannot be named in that script.
- A **network path as work folder** (`\\server\share`) now gives a clear message instead of an error from `DriveInfo`.
- A **non-numeric image INDEX** in `autounattend.xml` no longer aborts the check with a cast error; it is reported as a warning.
- The Defender marker file and the `.sha256` next to the ISO keep non-ASCII characters in the path / file name (UTF-8; the `.sha256` has no BOM, so `sha256sum -c` reads it).
- The launcher starts Windows PowerShell by its full path, so a `powershell.exe` lying next to the `.cmd` (the current folder is searched first) is never run with administrator rights.
- Redundant branch in the driver import removed.

## v3.3.0 — 2026-10-28

Windows 11 support, and a switch on page 1 to choose between Windows 10 and Windows 11.

**Upgrading from 3.2:** replace `Win10-ISO-Updater.cmd`. Your settings, the `signing` folder and the work folder are kept. A Windows 11 ISO you unpacked with an older version is detected again automatically the next time you download updates (or press *Re-read image info*).

### Added — Windows 11
- **Windows version switch on page 1**: *Windows 10* or *Windows 11*. It sets the *Download Windows 10/11 from Microsoft* button, the hint under it and the title of the ISO dialog. When you unpack an ISO, it follows the Windows that ISO really is. If you pick the other version while an ISO is unpacked, the page says so.
- **Windows 11 21H2, 22H2 / 23H2, 24H2 / LTSC 2024 and 25H2** (x64, ARM64) get automatic updates:
  - the cumulative update;
  - the Safe OS and Setup Dynamic Updates;
  - the .NET cumulative update;
  - for 22H2, the 23H2 enablement package (KB5027397).
- 21H2 is out of servicing and gets its last updates (2024-10). The Windows 10 ESU limit (2025-10) applies to Windows 10 only, so the *Newest month* box on page 3 is hidden for Windows 11.
- Windows 11 cumulative updates carry the servicing stack, so the 36-month servicing stack lookup is skipped. .NET 4.8.1 is built in, so it is not added.
- **Checkpoint cumulative updates (24H2 and later):** the catalog entry also holds the checkpoint update it builds on. Both are downloaded, and the checkpoint (the older KB) goes in first, for install.wim, WinRE and boot.wim.
- **DISM for Windows 11 on a Windows 10 PC:** Windows supports servicing an image only with a DISM of the same or a newer Windows.
  - When this PC's DISM is older than the image, the slipstream offers to install the **Windows ADK Deployment Tools** from Microsoft (signature-checked, the same installer already used as the `oscdimg` fallback).
  - The ADK's DISM is then used for that image. This PC's own DISM is not changed.
  - The background boot.wim / WinRE jobs and *Clean up* use the same DISM.
  - If you decline, the PC's DISM is tried, with a warning.
- The new ISO is named `Win11_<version>_<build>_<arch>_<date>.iso` for Windows 11, and its volume label starts with `W11_`.

### Changed
- The family detection and catalog searches moved from the v1 engine into `src/38_engine_windows.ps1`. The *Windows 10* in the catalog title patterns is now the image's Windows.
- The install check no longer says "Windows 10 Setup" for `$OEM$` folders.

### Tests
- The catalog suite covers:
  - every Windows 11 version and the old saved state without an OS;
  - the Windows 11 titles (24H2 vs 25H2 vs Server, ARM64 in lower case, .NET "Windows 11, version 24H2", Safe OS / Setup Dynamic Updates);
  - the 23H2 enablement package;
  - the checkpoint-first order;
  - the DISM choice (Windows 10 PC with and without the ADK, install yes/no, Windows 11 PC, version unreadable).
- The download suite covers Windows 11 24H2 (no SSU lookup, no .NET 4.8.1) and 22H2 (enablement package).
- The UI suite covers the version switch.
- In total there are 11 suites with about 350 checks.

## v3.2.0 — 2026-10-28

Signing NVIDIA drivers on page 5 now gets the speed-up of *New catalogs only for the INF files that need one*, with the change from [NVIDIA Modded Drivers Signer](https://github.com/j0p3s/nvidia-modded-drivers-signer) 1.5.0.

**Upgrading from 3.1:** replace `Win10-ISO-Updater.cmd`. Your settings, the `signing` folder and the work folder are kept. Sign your NVIDIA package again to get the faster method.

### Faster — signing NVIDIA drivers (page 5)
- **An edited INF whose catalog is shared gets a catalog of its own.** NVIDIA's `Display.Driver` INF files share one catalog (`nv_dispi.cat`).
  - In 3.1, a new catalog had to cover every INF that named it. So for NVIDIA the whole folder was catalogued again, and the isolated copy gained nothing.
  - Now the edited INF's `CatalogFile=` line points at `<name>_w10u.cat` (for example `nv_dispi_w10u.cat`), and only that INF is catalogued. Nothing else in the INF changes, and its encoding (ANSI, UTF-8, UTF-16) is kept.
  - The shared `nv_dispi.cat` stays as it is and stays valid for the INF files you did not edit.
  - This change is made in the work copy only, and only once Inf2Cat has succeeded. If it fails, the whole folder is catalogued as before, and the INF is not changed.
  - When NVCleanstall signed the shared catalog with its own certificate, every INF needs a new one. Each INF then gets its own catalog, and they are catalogued side by side instead of in one long Inf2Cat run.
- **Inf2Cat runs at the same time:** the default is now the number of processor cores up to 8 (was 4), as in signer 1.5.0.

### Not taken over from the signer
- Signer 1.5.0 backs up the original INF files before replacing them. Here only the work copy is changed; your original folder is never touched.

### Code and tests
- `Split-InfGroups` (catalog groups) is replaced by `Split-InfRuns`, `Get-OwnCatalogName` and `Set-InfCatalog`.
- `tests/sign-speed.tests.ps1` now covers:
  - NVIDIA's shared catalog with one edited INF;
  - a shared catalog signed by NVCleanstall (one run per INF);
  - the INF encodings.
- The stand-in signtool now reports an INF edited after its catalog was made.
- The suite has 60 checks; in total there are 11 suites with about 310 checks.

## v3.1.0 — 2026-10-28

Faster driver signing on page 5, with the speed-ups from [NVIDIA Modded Drivers Signer](https://github.com/j0p3s/nvidia-modded-drivers-signer) 1.1–1.4.

**Upgrading from 3.0:** replace `Win10-ISO-Updater.cmd`. Your settings, the `signing` folder and the work folder are kept. Packages you already signed stay in the ISO as they are; sign them again to use the faster method.

### Faster — signing modded drivers (page 5)
- **New catalogs only for the INF files that need one** (new option, on by default). Before, a folder with one edited INF got new catalogs for all of its INF files, so Inf2Cat checked all ~40 INF files of NVIDIA's `Display.Driver` against the ~1 GB package. Now Inf2Cat gets a copy of the folder with only the edited INF files (and any INF that shares their catalog file). The driver files in that copy are hard links, so making it takes no time and no extra space (on drives without hard links they are copied).
  - The other INF files keep their NVIDIA / Microsoft catalog and signature, and every INF stays in the package. Unlike *Only keep the INF files for this PC's hardware*, the driver still installs on any hardware, and NVIDIA's `setup.exe` keeps all its files.
  - If Inf2Cat fails on the copy, the whole folder is catalogued as before, and the log says so.
  - With *Re-sign every package*, all INF files get a new catalog, spread over several Inf2Cat runs.
- **Several Inf2Cat runs at the same time.** One Inf2Cat run uses one processor core. Folders, and groups of INF files within a folder, are now catalogued side by side. New box on page 5, *Inf2Cat runs at the same time*: 1–8, by default the number of processor cores up to 4.
- **All new catalogs are signed together**: up to 16 per signtool call instead of one call per catalog. If a batch fails, its files are signed one by one to find the one that failed.
- **Time left.** While Inf2Cat runs, the status line shows the estimated time left and the progress bar fills.
  - The estimate uses the size of the driver files, the number of INF files and how fast Inf2Cat was in earlier runs on this PC (`tools\inf2cat-speed.json`), so it gets more accurate each time.
  - The log gives the estimate before Inf2Cat starts.
  - With several runs, the status line shows how many are running and how many are done.

### Not taken over from the signer
- Signer 1.4.0 checks the INF files for one Windows version instead of seven. Win10 ISO Updater already checks a single target: Windows 10 for the ISO's architecture.
- Signer 1.2.1 moves the removed INF files to a backup folder instead of deleting them. Here the original folder is never touched; only the work copy is trimmed.
- Signer 1.3.0's *Fast* mode copies only the INF file. Here the copy also holds the driver files (as hard links), so the new catalog covers the files the INF installs.

### Code and tests
- `Invoke-Inf2CatQueue` runs Inf2Cat on a list of folders, a set number at the same time, and reads each run's output live. The single-folder `Invoke-Inf2Cat` uses it.
- New suite `tests/sign-speed.tests.ps1` covers:
  - isolated copies (hard links, catalogs left alone, a shared catalog, a leftover copy);
  - two runs at the same time;
  - the fallback to the whole folder;
  - a missing driver file;
  - batched signing;
  - the time estimate and the live status of several runs.
- The stand-in Inf2Cat now checks that the files an INF lists exist and logs each run. The stand-in signtool signs every file it is given.
- In total there are 11 suites with about 300 checks.

## v3.0.0 — 2026-10-27

Faster slipstream and downloads, a PC that stays awake through long jobs, progress on the taskbar, and an ISO build that never loses the previous ISO.

**Upgrading from 2.x:** replace `Win10-ISO-Updater.cmd`. Your settings, the `signing` folder and the work folder are kept, and all options keep their values.

### Faster
- **WinRE is updated in the background**, at the same time as the first edition of `install.wim` (and `boot.wim`). The edition waits for it only just before it is saved. Before, `install.wim` waited for the whole WinRE update (mount, servicing stack, Safe OS update, cleanup, export). The same option controls it, now *Update boot.wim and WinRE at the same time as install.wim* (page 7); with it off, everything runs one after the other, as before.
- WinRE is updated once. If that fails, it is no longer tried again for every following edition.
- **Find and download updates:** the standalone servicing stack lookup walks back up to 36 months of the catalog, one search per month. It now runs in the background while the cumulative update and the other packages are found and downloaded.
- *Run everything* with no edition ticked now says that keeping all editions takes about that many times as long as one.
- The status line shows every background job (boot.wim, WinRE, servicing stack lookup) next to the main one.

### Added — long jobs
- **The PC stays awake while a job runs.** Windows used to go to sleep partway through a 30–90 minute slipstream if nobody touched it. Sleep is now blocked until the job ends; the screen can still turn off.
- **Progress on the taskbar button.** It follows the progress bar, turns yellow while a question is waiting and red after an error. When a job ends or asks something while the window is in the background, the button flashes until you switch back.

### Changed — Build ISO
- **A failed build no longer deletes the previous ISO.** Before, an ISO with the same name and its `.sha256` were deleted before oscdimg started. Now oscdimg writes `<name>.iso.part`, which replaces the old ISO only when it is complete. A half-written `.part` file is removed.
- **Free space on the output drive is checked before oscdimg starts.** If an older ISO of the same name has to make room, it is deleted first, as before. Otherwise you are asked before a build that would run out of space.
- **An ISO that is mounted in Explorer or open in a virtual machine is reported up front**, with what to do, instead of as a "file in use" error.

### Code and tests
- The ISO build and the download step moved from the v1 engine into `src/36_engine_build.ps1` and `src/37_engine_download.ps1`.
- The background jobs share one set of functions (`Start-SideJob` / `Wait-SideJob` / `Stop-SideJob`), which used to be boot.wim only.
- Two new test suites: the ISO build against a stand-in `oscdimg`, and the download step against a stand-in catalog.
- The slipstream suite now covers WinRE: in the background vs. inline, and a failed WinRE update with two editions.
- The UI suite now covers the taskbar progress and several background jobs on the status line.
- In total there are 10 suites with about 250 checks.
- New `release` workflow (Actions → release → Run workflow). It checks the version and this changelog entry, rebuilds and tests, then publishes the tag and the GitHub release with `Win10-ISO-Updater.cmd` and its SHA-256 attached.

## v2.1.2 — 2026-10-25

### Fixed
- Page titles, card headings, labels (*Folder*, *Name*, *Newest month to integrate*), the detected image line, the certificate status and the answer file / `$OEM$` lines were nearly black on the dark background. They now use the theme's light text colours, and the grey help text is a little lighter.

## v2.1.1 — 2026-10-25

### Fixed
- **Clean up left the copied drivers, the answer file copy, the install check results, the logs and `state.json` behind.** New choices: *Copied drivers*, *Answer file copy and install check results*, *Logs*, and *Everything — empty the work folder and start from scratch*. "Everything" deletes only what the tool itself creates there (anything else in that folder is left alone) and resets the state; settings and the signing certificate next to the `.cmd` are kept.
- The ESU-cutoff warning pointed to *Options*; the month is set on the *Windows updates* page.

### Repository
- README: contents, screenshots section, Options / Tools pages, Activity panel, privacy section, download from Releases.
- New: `CONTRIBUTING.md`, `SECURITY.md`, issue forms (bug report, idea), pull request checklist, `.editorconfig`, `docs/screenshots/`.
- GitHub Actions run the test suites and check that `Win10-ISO-Updater.cmd` is the build of `src/`.

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
