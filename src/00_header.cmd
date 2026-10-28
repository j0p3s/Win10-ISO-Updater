@echo off
:: ===========================================================================
::  @@FILENAME@@  -  one file, graphical interface
::  Windows ISO Updater: the file name carries the version (vX.X.X).
::  - unpacks a Windows 10 or Windows 11 ISO and detects its build
::  - downloads its updates from the Microsoft Update Catalog
::  - slipstreams updates and drivers (this PC or a Drivers-Backup folder)
::  - re-signs modded drivers (NVCleanstall / edited INF, e.g. NVIDIA) with your
::    own certificate and installs them through $OEM$ + SetupComplete.cmd
::  - adds autounattend.xml and your own $OEM$ folder
::  - rebuilds a bootable BIOS + UEFI ISO
::  Tools it needs (oscdimg, Inf2Cat, signtool) are downloaded automatically.
::  Just double-click this file.
:: ===========================================================================
setlocal EnableExtensions DisableDelayedExpansion
title Windows ISO Updater
:: Windows PowerShell by its full path: cmd.exe looks in the current folder first, so a plain "powershell"
:: would run a powershell.exe lying next to this file - and with administrator rights.
set "PSEXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "PSEXE=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
fltmc >nul 2>&1 && goto :admin_ok
echo Requesting administrator rights...
set "W10U_SELF=%~f0"
"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath $env:W10U_SELF -Verb RunAs"
exit /b

:admin_ok
set "W10U_SELF=%~f0"
echo Starting Windows ISO Updater v@@VERSION@@ ...  (this window hides when the program opens)
"%PSEXE%" -NoProfile -STA -ExecutionPolicy Bypass -Command "$t=[IO.File]::ReadAllText($env:W10U_SELF);$i=$t.IndexOf('#'+'PS-BEGIN');Invoke-Expression $t.Substring($i)"
if errorlevel 1 pause
exit /b
