function Start-SleepCheckpoint {
    param([string]$CheckpointFile)
    if (-not $CheckpointFile) { throw "CheckpointFile required" }

    if (-not (Get-EventSubscriber -SourceIdentifier 'PowerEvent' -ErrorAction SilentlyContinue)) {
        Register-WmiEvent -Query "SELECT * FROM Win32_PowerManagementEvent" -SourceIdentifier 'PowerEvent' | Out-Null
    }

    Set-Variable -Name 'SleepCheckpointFile' -Scope Script -Value $CheckpointFile -Force
}

function Stop-SleepCheckpoint {
    if (Get-EventSubscriber -SourceIdentifier 'PowerEvent' -ErrorAction SilentlyContinue) {
        Unregister-Event -SourceIdentifier 'PowerEvent' -ErrorAction SilentlyContinue
    }
    Remove-Variable -Name 'SleepCheckpointFile' -Scope Script -ErrorAction SilentlyContinue
}

function Write-CheckpointNow {
    param(
        [Parameter(Mandatory)]
        [object]$StateObject,
        [string]$FilePath
    )

    $path = $FilePath
    if (-not $path) { $path = (Get-Variable -Name 'SleepCheckpointFile' -Scope Script -ErrorAction SilentlyContinue).Value }
    if (-not $path) { throw "No checkpoint file path configured. Call Start-SleepCheckpoint -CheckpointFile <path> or pass -FilePath." }

    try {
        $json = $StateObject | ConvertTo-Json -Depth 16
        $tmp = [System.IO.Path]::GetTempFileName()
        [System.IO.File]::WriteAllText($tmp, $json, [System.Text.Encoding]::UTF8)
        Move-Item -Path $tmp -Destination $path -Force
    } catch {
        try { $_ | Out-String | Out-File -FilePath $path -Encoding UTF8 -Force } catch { }
    }
}

function Save-SyncCheckpoint {
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,
        [Parameter(Mandatory)]
        [int]$ProjectsIndex,
        [Parameter(Mandatory)]
        [string]$Phase,           # e.g. "preconnect","pull","merge","push"
        [int]$ProjectDeviceIndex = 0,
        [Hashtable]$DeviceSerials = @{},
        [string]$ProjectName = $null,
        [object]$Extra = $null
    )

    $state = [ordered]@{
        version = 1
        savedAt = (Get-Date).ToString("o")
        projectsIndex = $ProjectsIndex
        projectName  = $ProjectName
        phase = $Phase
        deviceIndex = $ProjectDeviceIndex
        deviceSerials = $DeviceSerials
        extra = $Extra
    }

    Write-CheckpointNow -StateObject $state -FilePath $FilePath
}

function Load-SyncCheckpoint {
    param([Parameter(Mandatory)][string]$FilePath)
    if (-not (Test-Path $FilePath)) { return $null }
    try {
        $text = Get-Content -Path $FilePath -Raw -ErrorAction Stop
        return ConvertFrom-Json $text
    } catch {
        return $null
    }
}

function Prompt-ResumeSync {
    param(
        [Parameter(Mandatory)][string]$CheckpointFile,
        [Parameter(Mandatory)][object]$Projects,
        [switch]$Headless
    )

    if (-not (Test-Path $CheckpointFile)) { return $null }
    $ck = Load-SyncCheckpoint -FilePath $CheckpointFile
    if (-not $ck) {
        Remove-Item $CheckpointFile -ErrorAction SilentlyContinue
        return $null
    }

    $projIdx = $ck.projectsIndex
    $projName = $ck.projectName
    $phase = $ck.phase
    $devIdx = $ck.deviceIndex
    $deviceSerials = $ck.deviceSerials

    $summary = @()
    $summary += "Saved at: $($ck.savedAt)"
    $summary += "Project index: $projIdx"
    if ($projName) { $summary += "Project name: $projName" }
    $summary += "Phase: $phase"
    $summary += "Device index: $devIdx"
    if ($deviceSerials) { $summary += ("Device serials: {0}" -f ($deviceSerials.Keys -join ",")) }

    if ($Headless) {
        return @{ Resume = $true; Checkpoint = $ck }
    }

    Write-Host "Found existing sync checkpoint:"
    $summary | ForEach-Object { Write-Host "  $_" }
    $ans = Read-Host "Resume last sync? (Y)es / (N)o - default Y"
    if ($ans -eq '' -or $ans -match '^[yY]') {
        return @{ Resume = $true; Checkpoint = $ck }
    } else {
        Remove-Item $CheckpointFile -ErrorAction SilentlyContinue
        return $null
    }
}