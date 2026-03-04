# ADB Sync Orchestrator

ADB Sync Orchestrator coordinates file synchronisation between local projects and Android devices using adb. The primary entrypoint is `sync.ps1`.

## What sync.ps1 does
- Orchestrates syncing files between configured local projects and connected Android devices.
- Uses local config files (devices.json, projects.json) to determine targets and sync rules.
- Writes runtime logs to the `logs` folder (ignored by Git).

## Prerequisites
- Windows PowerShell
- Android Platform Tools (adb) available on PATH
- USB debugging enabled on target devices

Verify adb connectivity:
```
adb devices
```

## Configuration
- devices.json — per-device entries (device id / serial, optional labels). This file is local and git-ignored.
- projects.json — list of local projects and target paths on devices. Also local and git-ignored.

Example json configs:

devices.json
```json
{
    "devices": [{
            "name": "MyPhone",
            "ip": "192.168.0.10"
        },
        {
            "name": "MyTablet",
            "ip": "192.168.0.11"
        }
    ]
}
```

projects.json
```json
{
    "projectsDirectory": "C:\\path\\to\\projects",
    "projects": [{
        "name": "NomadSculpt",
        "exclude": [
            "tmp_session",
            "postprocess",
            "profiles",
            "data"
        ],
        "devices": [{
                "deviceName": "MyPhone",
                "remotePath": "/storage/emulated/0/Android/data/com.test.testapp/."
            },
            {
                "deviceName": "MyTablet",
                "remotePath": "/storage/emulated/0/Android/data/com.test.testapp/."
            }
        ]
    }]
}
```

## Usage
Open PowerShell in this folder and run:
```
# run with default execution policy
powershell -ExecutionPolicy Bypass -File .\sync.ps1

# or from current shell
.\sync.ps1
```
For script-specific flags and help, run:
```
.\sync.ps1 -? 
# or
Get-Help .\sync.ps1 -Full
```

## Troubleshooting
- If devices do not appear, ensure adb is on PATH and USB debugging is enabled.
- Check `logs` for runtime errors.
- If PowerShell blocks the script, use `-ExecutionPolicy Bypass` or adjust policy as needed.

## Notes
- `logs`, `devices.json`, and `projects.json` are git-ignored by default.
- Inspect and update the JSON config files to control what sync.ps1 operates on.
