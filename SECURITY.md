# Security

## Your signing key

The tool creates a self-signed code-signing certificate to re-sign modded drivers. Its private key is saved as `signing\DriverSigning.pfx` next to the `.cmd`.

- **Keep it private and backed up.** Anyone who has it can sign drivers that every PC installed from your ISO will trust.
- Only the public `DriverSigning.cer` goes into the ISO.
- If you think it leaked: delete the `signing` folder, remove the certificate from `certmgr.msc` (Personal, and on installed PCs Trusted Root + Trusted Publishers, subject `CN=Custom Driver Signing`), and sign your packages again — a new certificate is created.

## Your ISO

The ISO contains your `autounattend.xml`, which usually holds an account password and a Wi‑Fi key in plain text, and your `$OEM$` folder. Treat the ISO and the USB stick like those passwords.

## What the tool downloads

Only from Microsoft: the Update Catalog and its download servers (updates are checked against the SHA-1 in their file names), the Microsoft symbol server (`oscdimg.exe`, SHA-256 checked, ADK as fallback) and nuget.org (`Microsoft.Windows.SDK.BuildTools` / `Microsoft.Windows.WDK.x64`, for `signtool` and `Inf2Cat`; only those folders are extracted, nothing is installed). Nothing about you or your PC is sent anywhere.

## While it runs

- It needs administrator rights (DISM, mounting images, certificates).
- During signing, the certificate is trusted on this PC only for the check and removed again (stores that already trusted it are left alone).
- With *Let Windows Defender skip the work folder*, an exclusion for the work folder is added only for the job and removed afterwards (also at the next start if the program was closed during a job).

## Reporting a vulnerability

Please don't open a public issue. Use GitHub's **Report a vulnerability** (Security tab → Advisories) on this repository, with steps to reproduce.
