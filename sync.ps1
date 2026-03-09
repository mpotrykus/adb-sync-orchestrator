param(
    [string]$BaseDir = $PSScriptRoot,
    [switch]$Headless,
    [switch]$Notify
)

$log = Join-Path $PSScriptRoot "sync.log"
Start-Transcript -Path $log -Append

$ErrorActionPreference = "Stop"

$global:Headless = $Headless.IsPresent

# load modules
. (Join-Path $BaseDir "lib\helpers.ps1")
. (Join-Path $BaseDir "lib\mdns.ps1")
. (Join-Path $BaseDir "lib\lock.ps1")
. (Join-Path $BaseDir "lib\adb.ps1")
. (Join-Path $BaseDir "lib\device.ps1")
. (Join-Path $BaseDir "lib\notify.ps1")
. (Join-Path $BaseDir "lib\log.ps1")
. (Join-Path $BaseDir "lib\checkpoint.ps1")

# notify on unhandled errors
trap {
    $err = $_
    try {
        Set-TrayIconStage -Stage 'error' | Out-Null
        Manage-Error -Message ($err.Exception.Message) -ExceptionMessage ($err.Exception.InnerException.Message)
        Close-TrayIcon
    } catch { }
    throw $err
}

function Complete-Project {
    param(
        [string]$ProjectRoot = $null,
        [datetime]$ProjectStart = $null,
        [bool]$RemoveLock = $true
    )

    if ($ProjectStart) {
        $__project_elapsed = (Get-Date) - $ProjectStart
        $elapsedStr = Format-DurationHighestUnit -Start $ProjectStart -End (Get-Date)
        Manage-Info ("Project '{0}' completed in {1}." -f $project.name, $elapsedStr)
    } else {
        Manage-Info "Project '$($project.name)' completed."
    }

    Write-Host "=================="
    Write-Host ""
    if ($RemoveLock -and -not [string]::IsNullOrWhiteSpace($ProjectRoot)) { Remove-SyncLock $ProjectRoot }

    # indicate success visually
    try { Set-TrayIconStage -Stage 'success' | Out-Null } catch {}
}

function Initialize-Sync {
    param([string]$BaseDir, [switch]$Headless)

    $devices  = Import-Json (Join-Path $BaseDir "devices.json")
    $projects = Import-Json (Join-Path $BaseDir "projects.json")

    $__adbsync_start = Get-Date
    Write-Host "Starting sync at $__adbsync_start"
    Write-Host ""

    $checkpointFile = Join-Path $BaseDir ".sync_checkpoint.json"
    Start-SleepCheckpoint -CheckpointFile $checkpointFile

    New-TrayIcon -MakeGlobal -Tooltip "ADB Sync" | Out-Null
    Set-TrayIconStage -Stage 'connect' | Out-Null
    Update-TrayTooltip -Tooltip "ADB Sync: starting" | Out-Null

    $resumeResp = Prompt-ResumeSync -CheckpointFile $checkpointFile -Projects $projects -Headless:$Headless
    $startProjectIndex = 0
    $resumeCheckpoint = $null
    if ($resumeResp -and $resumeResp.Resume) {
        $resumeCheckpoint = $resumeResp.Checkpoint
        $startProjectIndex = [int]$resumeCheckpoint.projectsIndex
        Manage-Info "Resuming sync from project index $startProjectIndex (phase: $($resumeCheckpoint.phase))"
    }

    return @{
        devices = $devices
        projects = $projects
        checkpointFile = $checkpointFile
        startProjectIndex = $startProjectIndex
        resumeCheckpoint = $resumeCheckpoint
        adbsync_start = $__adbsync_start
    }
}

function Prepare-Project {
    param(
        [Parameter(Mandatory)][object]$Project,
        [Parameter(Mandatory)][int]$Index,
        [Parameter(Mandatory)][object]$ProjectsObj,
        [object]$ResumeCheckpoint
    )

    $__project_start = Get-Date
    Write-Host "=== Project: $($Project.name) ==="
    Show-TrayBalloon -Title "Sync starting" -Message "Starting sync for '$($Project.name)'..." -TimeoutMs 3000
    Update-TrayTooltip -Tooltip ("Project: {0} - preparing" -f $Project.name) | Out-Null

    $projectRoot = Join-Path $ProjectsObj.projectsDirectory $Project.name
    Test-Folder $projectRoot

    $masterPath = Join-Path $projectRoot "master"
    Test-Folder $masterPath

    $projectLogDir = Join-Path $projectRoot "logs"
    Test-Folder $projectLogDir

    $gotLock = Get-SyncLock $projectRoot

    if (-not $gotLock) {
        Manage-Info "Another sync appears to be running for project '$($Project.name)'. Skipping."
        Complete-Project -ProjectRoot $null -ProjectStart $__project_start -RemoveLock:$false -ProjectName $Project.name | Out-Null
        return $null
    }

    return @{
        projectRoot = $projectRoot
        masterPath = $masterPath
        projectLogDir = $projectLogDir
        projectStart = $__project_start
    }
}

function Get-ProjectDeviceSerials {
    param(
        [Parameter(Mandatory)][object]$Project,
        [Parameter(Mandatory)][object]$DevicesObj
    )

    $deviceSerials = @{}
    $allConnected = $true
    foreach ($pd in $Project.devices) {
        try {
            $device = Get-DeviceByName $DevicesObj $pd.deviceName
            $serial = Ensure-DeviceConnected $device
            $deviceSerials[$device.name] = $serial
        } catch {
            Manage-Error -Message "Failed to connect to device '$($pd.deviceName)'" -ExceptionMessage $_.Exception.Message
            $allConnected = $false
            break
        }
    }

    return @{ ok = $allConnected; deviceSerials = $deviceSerials }
}

function Ensure-AppNotRunning {
    param(
        [Parameter(Mandatory)][object]$Project,
        [Parameter(Mandatory)][hashtable]$DeviceSerials
    )

    if (-not $Project.appPackage) { return $true }

    foreach ($deviceName in $DeviceSerials.Keys) {
        $serial = $DeviceSerials[$deviceName]
        if (Test-AndroidAppRunning -serial $serial -package $Project.appPackage) {
            Write-Warning "App $($Project.appPackage) is running on device $deviceName. Skipping project '$($Project.name)'."
            return $false
        }
    }
    return $true
}

function Pull-ProjectDevices {
    param(
        [Parameter(Mandatory)][object]$Project,
        [Parameter(Mandatory)][int]$Index,
        [Parameter(Mandatory)][object]$DevicesObj,
        [Parameter(Mandatory)][hashtable]$DeviceSerials,
        [Parameter(Mandatory)][string]$CheckpointFile,
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$MasterPath,
        [Parameter(Mandatory)][string]$ProjectLogDir,
        [object]$ResumeCheckpoint
    )

    $excludeList = @()
    if ($Project.exclude) { $excludeList = $Project.exclude }

    $projectResumePhase = $null
    $projectResumeDeviceIndex = 0
    if ($ResumeCheckpoint -and ($Index -eq [int]$ResumeCheckpoint.projectsIndex)) {
        $projectResumePhase = $ResumeCheckpoint.phase
        $projectResumeDeviceIndex = [int]$ResumeCheckpoint.deviceIndex
    }

    for ($di = 0; $di -lt $Project.devices.Count; $di++) {
        if ($projectResumePhase -and $projectResumePhase -ne 'pull' -and $projectResumePhase -ne $null) { break }
        if ($ResumeCheckpoint -and $Index -eq [int]$ResumeCheckpoint.projectsIndex -and $di -lt $projectResumeDeviceIndex) { continue }

        $pd = $Project.devices[$di]
        $device = Get-DeviceByName $DevicesObj $pd.deviceName
        $serial = $DeviceSerials[$device.name]

        $deviceMirrorPath = Get-StagingPath $ProjectRoot $device.name
        $logFile = Join-Path $ProjectLogDir ("{0}_{1}_pull.log" -f $Project.name, $device.name)

        Save-SyncCheckpoint -FilePath $CheckpointFile `
                            -ProjectsIndex $Index `
                            -ProjectName $Project.name `
                            -Phase "pull" `
                            -ProjectDeviceIndex $di `
                            -DeviceSerials $DeviceSerials

        Manage-Info "Pulling from $($device.name)..."
        Set-TrayIconStage -Stage 'pull' | Out-Null
        Update-TrayTooltip -Tooltip ("Pulling: {0} @ {1}" -f $Project.name, $device.name) | Out-Null
        $remotePathForPull = Convert-PathForContents $pd.remotePath

        Invoke-AdbSync -direction "pull" `
                       -serial $serial `
                       -sourcePath $remotePathForPull `
                       -destPath $deviceMirrorPath `
                       -excludeList $excludeList `
                       -logFile $logFile `
                       -delete

        Manage-Info "Merging into master..."
        Set-TrayIconStage -Stage 'merge' | Out-Null
        Update-TrayTooltip -Tooltip ("Merging: {0} @ {1}" -f $Project.name, $device.name) | Out-Null
        Merge-ToMaster $deviceMirrorPath $MasterPath $logFile

        Manage-Info "Saving last complete state for $($device.name)..."
        Set-TrayIconStage -Stage 'success' | Out-Null
        Update-TrayTooltip -Tooltip ("Saving state: {0} @ {1}" -f $Project.name, $device.name) | Out-Null
        $lastCompleteRoot = Join-Path $ProjectRoot ".sync_last_complete"
        Test-Folder $lastCompleteRoot
        $lastCompletePath = Join-Path $lastCompleteRoot $device.name
        Remove-Item $lastCompletePath -Recurse -Force -ErrorAction SilentlyContinue
        Copy-Item -Path $deviceMirrorPath -Destination $lastCompletePath -Recurse -Force

        Remove-Item $deviceMirrorPath -Recurse -Force -ErrorAction SilentlyContinue

        Save-SyncCheckpoint -FilePath $CheckpointFile `
                            -ProjectsIndex $Index `
                            -ProjectName $Project.name `
                            -Phase "pull" `
                            -ProjectDeviceIndex ($di + 1) `
                            -DeviceSerials $DeviceSerials
    }
}

function Push-ProjectDevices {
    param(
        [Parameter(Mandatory)][object]$Project,
        [Parameter(Mandatory)][int]$Index,
        [Parameter(Mandatory)][object]$DevicesObj,
        [Parameter(Mandatory)][hashtable]$DeviceSerials,
        [Parameter(Mandatory)][string]$CheckpointFile,
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$MasterPath,
        [Parameter(Mandatory)][string]$ProjectLogDir,
        [object]$ResumeCheckpoint
    )

    $excludeList = @()
    if ($Project.exclude) { $excludeList = $Project.exclude }

    $projectResumePhase = $null
    $projectResumeDeviceIndex = 0
    if ($ResumeCheckpoint -and ($Index -eq [int]$ResumeCheckpoint.projectsIndex)) {
        $projectResumePhase = $ResumeCheckpoint.phase
        $projectResumeDeviceIndex = [int]$ResumeCheckpoint.deviceIndex
    }

    Save-SyncCheckpoint -FilePath $CheckpointFile `
                        -ProjectsIndex $Index `
                        -ProjectName $Project.name `
                        -Phase "push" `
                        -ProjectDeviceIndex 0 `
                        -DeviceSerials $DeviceSerials

    for ($di = 0; $di -lt $Project.devices.Count; $di++) {
        if ($projectResumePhase -and ($projectResumePhase -eq 'push' -and $di -lt $projectResumeDeviceIndex)) { continue }

        $pd = $Project.devices[$di]
        $device = Get-DeviceByName $DevicesObj $pd.deviceName
        $serial = $DeviceSerials[$device.name]
        $logFile = Join-Path $ProjectLogDir ("{0}_{1}_push.log" -f $Project.name, $device.name)

        Save-SyncCheckpoint -FilePath $CheckpointFile `
                            -ProjectsIndex $Index `
                            -ProjectName $Project.name `
                            -Phase "push" `
                            -ProjectDeviceIndex $di `
                            -DeviceSerials $DeviceSerials

        Manage-Info "Pushing master -> $($device.name)..."
        Set-TrayIconStage -Stage 'push' | Out-Null
        Update-TrayTooltip -Tooltip ("Pushing: {0} -> {1}" -f $Project.name, $device.name) | Out-Null
        $sourcePathForPush = Convert-PathForContents $MasterPath
        $destPathForPush   = Convert-PathForContents $pd.remotePath

        Invoke-AdbSync -direction "push" `
                       -serial $serial `
                       -sourcePath $sourcePathForPush `
                       -destPath $destPathForPush `
                       -excludeList $excludeList `
                       -logFile $logFile `
                       -delete

        Save-SyncCheckpoint -FilePath $CheckpointFile `
                            -ProjectsIndex $Index `
                            -ProjectName $Project.name `
                            -Phase "push" `
                            -ProjectDeviceIndex ($di + 1) `
                            -DeviceSerials $DeviceSerials
    }
}

function Invoke-Project {
    param(
        [Parameter(Mandatory)][object]$Project,
        [Parameter(Mandatory)][int]$Index,
        [Parameter(Mandatory)][object]$ProjectsObj,
        [Parameter(Mandatory)][object]$DevicesObj,
        [Parameter(Mandatory)][string]$CheckpointFile,
        [object]$ResumeCheckpoint,
        [switch]$Headless
    )

    $prep = Prepare-Project -Project $Project -Index $Index -ProjectsObj $ProjectsObj -ResumeCheckpoint $ResumeCheckpoint
    if (-not $prep) { return }

    $getSerials = Get-ProjectDeviceSerials -Project $Project -DevicesObj $DevicesObj
    if (-not $getSerials.ok) {
        Complete-Project $prep.projectRoot -ProjectStart $prep.projectStart
        return
    }
    $deviceSerials = $getSerials.deviceSerials
    Update-TrayTooltip -Tooltip ("Project: {0} - devices connected" -f $Project.name) | Out-Null

    if (-not (Ensure-AppNotRunning -Project $Project -DeviceSerials $deviceSerials)) {
        Update-TrayTooltip -Tooltip ("Project: {0} - app running; skipping" -f $Project.name) | Out-Null
        Complete-Project $prep.projectRoot -ProjectStart $prep.projectStart
        return
    }

    Pull-ProjectDevices -Project $Project `
                        -Index $Index `
                        -DevicesObj $DevicesObj `
                        -DeviceSerials $deviceSerials `
                        -CheckpointFile $CheckpointFile `
                        -ProjectRoot $prep.projectRoot `
                        -MasterPath $prep.masterPath `
                        -ProjectLogDir $prep.projectLogDir `
                        -ResumeCheckpoint $ResumeCheckpoint

    Push-ProjectDevices -Project $Project `
                        -Index $Index `
                        -DevicesObj $DevicesObj `
                        -DeviceSerials $deviceSerials `
                        -CheckpointFile $CheckpointFile `
                        -ProjectRoot $prep.projectRoot `
                        -MasterPath $prep.masterPath `
                        -ProjectLogDir $prep.projectLogDir `
                        -ResumeCheckpoint $ResumeCheckpoint

    Complete-Project $prep.projectRoot -ProjectStart $prep.projectStart

    Save-SyncCheckpoint -FilePath $CheckpointFile `
                        -ProjectsIndex ($Index + 1) `
                        -ProjectName $null -Phase "preconnect" `
                        -ProjectDeviceIndex 0 `
                        -DeviceSerials @{}
}

try {
    $init = Initialize-Sync -BaseDir $BaseDir -Headless:$Headless

    for ($pi = $init.startProjectIndex; $pi -lt $init.projects.projects.Count; $pi++) {
        Write-Host $init.projects.projects
        Write-Host "Starting project index $pi..."
        $project = $init.projects.projects[$pi]
        Invoke-Project -Project $project `
                       -Index $pi `
                       -ProjectsObj $init.projects `
                       -DevicesObj $init.devices `
                       -CheckpointFile $init.checkpointFile `
                       -ResumeCheckpoint $init.resumeCheckpoint `
                       -Headless:$Headless
    }

    $__adbsync_elapsed = (Get-Date) - $init.adbsync_start
    $elapsedStr = Format-DurationHighestUnit -Start $init.adbsync_start -End (Get-Date)
    Manage-Info ("Sync completed in {0}." -f $elapsedStr)

    Close-TrayIcon
}
catch {
    Set-TrayIconStage -Stage 'error' | Out-Null
    Manage-Error -Message "An unhandled error occurred: $_" -ExceptionMessage $_.Exception.Message
}
finally {
    Stop-SleepCheckpoint
    if (Test-Path $init.checkpointFile) { Remove-Item $init.checkpointFile -ErrorAction SilentlyContinue }
    Stop-Transcript
}