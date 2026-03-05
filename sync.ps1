param(
    [string]$BaseDir = $PSScriptRoot,
    [switch]$Headless
)

$ErrorActionPreference = "Stop"
$maxLockAgeHr = 4

# expose headless mode to dot-sourced modules
$global:Headless = $Headless.IsPresent

# load modules
. (Join-Path $BaseDir "lib\helpers.ps1")
. (Join-Path $BaseDir "lib\mdns.ps1")
. (Join-Path $BaseDir "lib\lock.ps1")
. (Join-Path $BaseDir "lib\adb.ps1")
. (Join-Path $BaseDir "lib\device.ps1")

# main orchestration (kept compact; uses functions from modules)
try {
    $devices  = Import-Json (Join-Path $BaseDir "devices.json")
    $projects = Import-Json (Join-Path $BaseDir "projects.json")

    foreach ($project in $projects.projects) {

        Write-Host ""
        Write-Host "=== Project: $($project.name) ==="

        $projectRoot = Join-Path $projects.projectsDirectory $project.name
        Test-Folder $projectRoot

        $masterPath = Join-Path $projectRoot "master"
        Test-Folder $masterPath

        $projectLogDir = Join-Path $projectRoot "logs"
        Test-Folder $projectLogDir

        if (-not (Get-SyncLock $projectRoot $maxLockAgeHr)) { continue }

        # Ensure all devices are connected before doing any work.
        $deviceSerials = @{}
        $allConnected = $true
        foreach ($pd in $project.devices) {
            try {
                $device = Get-DeviceByName $devices $pd.deviceName
                $serial = Ensure-DeviceConnected $device
                $deviceSerials[$device.name] = $serial
            }
            catch {
                Write-Warning "Failed to connect to device '$($pd.deviceName)': $_"
                $allConnected = $false
                break
            }
        }

        if (-not $allConnected) {
            Write-Warning "Not all devices connected for project '$($project.name)'. Skipping project."
            Remove-SyncLock $projectRoot
            continue
        }

        # If an appPackage is specified, ensure it's NOT running on ANY device.
        if ($project.appPackage) {
            $appRunning = $false
            foreach ($deviceName in $deviceSerials.Keys) {
                $serial = $deviceSerials[$deviceName]
                if (Test-AndroidAppRunning -serial $serial -package $project.appPackage) {
                    Write-Warning "App $($project.appPackage) is running on device $deviceName. Skipping project $($project.name)."
                    $appRunning = $true
                    break
                }
            }
            if ($appRunning) {
                Remove-SyncLock $projectRoot
                continue
            }
        }

        $excludeList = @()
        if ($project.exclude) { $excludeList = $project.exclude }

        # PULL
        foreach ($pd in $project.devices) {
            $device = Get-DeviceByName $devices $pd.deviceName
            $serial = $deviceSerials[$device.name]

            $deviceMirrorPath = Get-StagingPath $projectRoot $device.name
            $logFile = Join-Path $projectLogDir ("{0}_{1}_pull.log" -f $project.name, $device.name)

            Write-Host "Pulling from $($device.name)..."
            $remotePathForPull = Convert-PathForContents $pd.remotePath

            Invoke-AdbSync -direction "pull" `
                           -serial $serial `
                           -sourcePath $remotePathForPull `
                           -destPath $deviceMirrorPath `
                           -excludeList $excludeList `
                           -logFile $logFile `
                           -delete

            Write-Host "Merging into master..."
            Merge-ToMaster $deviceMirrorPath $masterPath $logFile

            # Save last complete state before removing staging
            Write-Host "Saving last complete state for $($device.name)..."
            $lastCompleteRoot = Join-Path $projectRoot ".sync_last_complete"
            Test-Folder $lastCompleteRoot
            $lastCompletePath = Join-Path $lastCompleteRoot $device.name
            Remove-Item $lastCompletePath -Recurse -Force -ErrorAction SilentlyContinue
            Copy-Item -Path $deviceMirrorPath -Destination $lastCompletePath -Recurse -Force

            Remove-Item $deviceMirrorPath -Recurse -Force -ErrorAction SilentlyContinue
        }

        # PUSH
        foreach ($pd in $project.devices) {
            $device = Get-DeviceByName $devices $pd.deviceName
            $serial = $deviceSerials[$device.name]
            $logFile = Join-Path $projectLogDir ("{0}_{1}_push.log" -f $project.name, $device.name)

            Write-Host "Pushing master -> $($device.name)..."
            $sourcePathForPush = Convert-PathForContents $masterPath
            $destPathForPush   = Convert-PathForContents $pd.remotePath

            Invoke-AdbSync -direction "push" `
                           -serial $serial `
                           -sourcePath $sourcePathForPush `
                           -destPath $destPathForPush `
                           -excludeList $excludeList `
                           -logFile $logFile `
                           -delete
        }

        Remove-SyncLock $projectRoot
    }

    Write-Host ""
    Write-Host "All projects synced."
}
finally {
    # global cleanup hook if you ever need it
}
