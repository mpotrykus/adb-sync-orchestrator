# ADB Sync Orchestrator

ADB Sync Orchestrator coordinates file synchronization between local projects and Android devices using adb. The primary entrypoint is `sync.ps1`.

## Quick Start
- Ensure Windows PowerShell and Android Platform Tools (adb) are installed and `adb` is on PATH.
- Enable USB debugging (or make sure devices are reachable over network).
- Place `devices.json` and `projects.json` next to the scripts (these files are local and typically git-ignored).

Run a sync interactively:
```
powershell -ExecutionPolicy Bypass -File .\sync.ps1
# or from current folder
.\sync.ps1
```

Run headless (non-interactive):
```
powershell -ExecutionPolicy Bypass -File .\sync.ps1 -Headless
```

Run the tray agent (keeps a small system tray icon and polls status):
```
powershell -ExecutionPolicy Bypass -File .\tray_agent.ps1
```
The tray agent ensures it runs in STA (required for WinForms) and will relaunch itself as needed.

## What sync.ps1 does
- Orchestrates syncing files between configured local projects and connected Android devices.
- Uses config files (`devices.json`, `projects.json`) to determine targets and sync rules.
- Writes runtime logs into each project's `logs` folder.

## Configuration overview

devices.json
```json
{
  "devices": [
    { "name": "MyPhone", "ip": "192.168.0.10" },
    { "name": "MyTablet", "ip": "192.168.0.11" }
  ]
}
```

projects.json
```json
{
  "projectsDirectory": "C:\\path\\to\\projects",
  "projects": [
    {
      "name": "Test",
      "appPackage": "com.test.testapp", # optional, used to check if app is running before syncing
      "exclude": ["tmp_session","postprocess","profiles","data"],
      "devices": [
        { "deviceName": "MyPhone", "remotePath": "/storage/emulated/0/Android/data/com.test.testapp/." },
        { "deviceName": "MyTablet", "remotePath": "/storage/emulated/0/Android/data/com.test.testapp/." }
      ]
    }
  ]
}
```

Key fields:
- projectsDirectory — root local folder containing project subfolders.
- remotePath — path on the Android device to sync (can end with `.` as shown).
- exclude — list of names to exclude during sync.

## Tray agent behavior
- Polls the projects directory and updates a system tray icon/status.
- Double-click tray icon opens the projects directory in Explorer.
- Right-click menu: "Run Sync Now" launches `sync.ps1`, "Exit" quits the agent.

## Logs and state
- Each project has a `logs` folder where per-device pull/push logs are written.
- A `.sync_last_complete` directory stores last saved complete device states.
- Sync locks are used to prevent concurrent runs; stale locks are cleaned after a configurable age.

## Troubleshooting
- If devices do not appear: ensure `adb devices` shows them and USB debugging is enabled.
- If adb is not found: ensure Android Platform Tools are installed and added to PATH.
- Check the per-project `logs` folder for errors and details.
- If PowerShell blocks execution, run with `-ExecutionPolicy Bypass` or adjust system policy.

## Notes
- `logs`, `devices.json`, and `projects.json` are typically git-ignored.
- The codebase is modular: helper modules live under `lib\` (helpers, adb, device, lock, mdns).
- Use `.\sync.ps1 -?` or `Get-Help .\sync.ps1 -Full` for script-specific flags.
