# Contributing

Thanks for helping. Windows ISO Updater is one `.cmd` file built from the parts in [`src/`](src).

## Reporting a bug

Open an issue with the **Bug report** form. The most useful things to include:

- the version (first console line: `Starting Windows ISO Updater v3.x.x ...`)
- what you did and on which page
- the last 50–100 lines of `C:\W10U\logs\engine.log` (and `dism.log` for DISM errors)

**Before posting a log, remove anything private**: your user name in paths, computer name, product keys, and never paste your `autounattend.xml` with passwords or Wi‑Fi keys in it.

## Changing the code

1. Edit the files in `src/`, never `Windows-ISO-updater-GUI_vX.X.X.cmd` directly — it is generated.
2. Rebuild:
   ```
   python src/build.py
   ```
   The output must stay ASCII with CRLF line endings (`build.py` checks the ASCII part; `.gitattributes` keeps the CRLF).
3. Run the tests (PowerShell 7 on Linux or macOS):
   ```
   pwsh tests/run-tests.ps1
   ```
4. Test on Windows too for anything that touches DISM, WPF or driver installs — the test suite uses stand-ins for those.
5. Commit both `src/` and the rebuilt `Windows-ISO-updater-GUI_vX.X.X.cmd` (the build removes the older one — commit that deletion too), and add a line to [CHANGELOG.md](CHANGELOG.md).

## Releasing

1. In `src/`, set the version in `10_engine_head.ps1` (`$Script:AppVersion`) — the only place: the build puts it in the file name, the header and the window. Also update the README badge and start line, and the bug report form.
2. Add a `## vX.Y.Z — date` entry to `CHANGELOG.md`. It becomes the release notes.
3. Rebuild, run the tests and merge to `main`.
4. Go to **Actions → release → Run workflow** on `main`. Enter the version and, optionally, a title.

The workflow checks the version and the changelog entry, rebuilds and tests. It then creates the tag and the GitHub release, with `Windows-ISO-updater-GUI_vX.Y.Z.cmd` and its `.sha256` attached.

## Code notes

- The engine runs under **Windows PowerShell 5.1**: variable names are case-insensitive (`$u` and `$U` are the same variable), `ConvertFrom-Json` does not unroll top-level arrays, and stderr of console tools becomes an error under `$ErrorActionPreference = 'Stop'` — use `Invoke-Native` / `Invoke-Exe` for console tools.
- Long jobs run in a background runspace; `Write-Host` there goes to the Activity panel, `Write-Host -NoNewline` to the status line.
- Keep user-facing text plain and short.

## Never commit

`signing/`, `*.pfx`, `*.p12`, `Windows-ISO-Updater.settings.json`, `Win10-ISO-Updater.settings.json`, work folders, ISOs or WIM files, real answer files. They are in [`.gitignore`](.gitignore) — please don't force-add them.
