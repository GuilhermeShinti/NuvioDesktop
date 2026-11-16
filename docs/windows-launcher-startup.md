# Windows launcher fails with `GetMessage() failed` (error 1400)

## Symptom

Launching the installed Windows app shows a dialog like:

```
Nuvio.exe

GetMessage() failed. System error [1400]
(system error 1400 (The window handle is invalid))
```

The app never opens. After dismissing the dialog, `Nuvio.exe` may stay
"Suspended" in Task Manager. The error is shown before any Nuvio window or log.

## Cause

`Nuvio.exe` is a native **jpackage launcher**, not the Java application. It is
not built from this repository's Kotlin code.

On the first launch after installation, jpackage restarts the launcher once so
that `<install>\app` is added to `PATH` (the app image needs that directory for
DLL resolution). While waiting for the child process, the launcher pumps
Windows messages through a hidden message-only window in
[`WinLauncher.cpp`](https://github.com/openjdk/jdk/blob/master/src/jdk.jpackage/windows/native/applauncher/WinLauncher.cpp)
(`RunExecutorWithMsgLoop`):

```cpp
while ((bRet = GetMessage(&msg, instance.hwnd, 0, 0)) != 0) {
    if (bRet == -1) {
        JP_THROW(SysError("GetMessage() failed", GetMessage));
```

`GetMessage` returned `-1`, and the reported `GetLastError()` was
`1400` = `ERROR_INVALID_WINDOW_HANDLE`. The JVM is never started, so no
application-level workaround can run.

This is an upstream jpackage/Windows interaction, not a Nuvio setting or
codec problem. It has been reported with several jpackage apps on Windows 11
24H2/25H2. A known trigger is Brazilian internet-banking security software
(**Warsaw** / **G-Buster** / `GbPlugin`), which hooks window handling and
invalidates hidden windows; see the
[XIVLauncher investigation](https://github.com/goatcorp/FFXIVQuickLauncher/issues/1569)
and the [Minecraft launcher report](https://mojira.dev/MCL-9024).

Nuvio tracks the issue in
[#829](https://github.com/NuvioMedia/NuvioDesktop/issues/829).

## Fix in the installer

The Windows MSI now appends `<install>\app` to the machine `PATH` during
installation and removes it on uninstall
(`scripts/windows/patch-msi-launcher-path.ps1`). When that directory is already
on `PATH`, the launcher skips the restart/message-loop path and starts the JVM
in-process, so `GetMessage` is never called.

This applies to **new installs and upgrades** built from this change onward.
Updating Nuvio alone does not fix an existing installation's environment until
the new MSI has been installed.

The installer broadcasts the environment change when it finishes. If the first
launch still fails, sign out and back in (or reboot) so Explorer picks up the
updated `PATH`.

## Manual workaround for existing installs

### 1. Add the app directory to `PATH` and relaunch

Find the directory containing `Nuvio.exe`, `app\`, and `runtime\` (normally
`C:\Program Files\Nuvio`). Then, from `cmd.exe`:

```bat
taskkill /IM Nuvio.exe /F
set "PATH=%PATH%;C:\Program Files\Nuvio\app"
"C:\Program Files\Nuvio\Nuvio.exe"
```

PowerShell:

```powershell
$env:Path += ";C:\Program Files\Nuvio\app"
& "C:\Program Files\Nuvio\Nuvio.exe"
```

No trailing backslash: the launcher compares `PATH` entries exactly. If this
works, add `C:\Program Files\Nuvio\app` permanently through
"Edit environment variables for your account" or use a small `.bat` shortcut.

### 2. Start the bundled JVM directly

```bat
"C:\Program Files\Nuvio\runtime\bin\javaw.exe" ^
  --add-opens=java.desktop/java.awt=ALL-UNNAMED ^
  --add-opens=java.desktop/sun.awt.windows=ALL-UNNAMED ^
  -Dcompose.application.configure.swing.globals=true ^
  -Dskiko.library.path="C:\Program Files\Nuvio\app" ^
  -cp "C:\Program Files\Nuvio\app\*" ^
  com.nuvio.app.MainKt
```

If icons or strings are missing, copy the remaining `java-options` from
`C:\Program Files\Nuvio\app\Nuvio.cfg`.

### 3. Check for Warsaw / G-Buster

If the error persists, look for "Warsaw", "G-Buster", or "GbPlugin" in
Add/Remove Programs and in `services.msc`. Temporarily uninstalling or
disabling it is the definitive test. Reinstall it afterwards, or use a separate
machine/VM for banking.
