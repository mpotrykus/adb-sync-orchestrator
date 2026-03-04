param(
    [string]$BaseDir = $PSScriptRoot
)

$ErrorActionPreference = "Stop"

# -------------------------
# Paths and helpers
# -------------------------
$devicesPath  = Join-Path $BaseDir "devices.json"
$projectsPath = Join-Path $BaseDir "projects.json"
$logsRoot     = Join-Path $BaseDir "logs"

function Load-Json($path) {
    if (!(Test-Path $path)) { throw "Missing JSON file: $path" }
    Get-Content $path -Raw | ConvertFrom-Json
}

function Ensure-Folder($path) {
    if (!(Test-Path $path)) { New-Item -ItemType Directory -Path $path | Out-Null }
}

function Get-DeviceByName($devices, $name) {
    $dev = $devices.devices | Where-Object { $_.name -eq $name }
    if (-not $dev) { throw "Device '$name' not found in devices.json" }
    return $dev
}

function Normalize-PathForContents {
    param([string]$remotePath)
    if ($remotePath.EndsWith("/.")) { $remotePath = $remotePath.Substring(0, $remotePath.Length - 2) }
    $remotePath = $remotePath.TrimEnd('/')
    return "$remotePath/."
}

# -------------------------
# mDNS-based ADB port discovery
# -------------------------
function Get-ADBDevicesViaMDNS {
    param(
    )

    $dnsSd = "dns-sd.exe"
    $browseFile = [IO.Path]::GetTempFileName()
    $resolveFile = [IO.Path]::GetTempFileName()
    $services = @()

    # Browse for ADB services
    $browseProc = Start-Process $dnsSd -ArgumentList "-B _adb-tls-connect._tcp local" -NoNewWindow -RedirectStandardOutput $browseFile -PassThru
    Start-Sleep 3
    Stop-Process $browseProc -Force

    $browseLines = Get-Content $browseFile
    Remove-Item $browseFile -ErrorAction SilentlyContinue

    foreach ($line in $browseLines) {
        if ($line -match "\sAdd\s" -and $line -match "_adb-tls-connect") {
            $parts = $line.Trim() -split "\s{2,}"
            $instance = $parts[-1]
            if (-not ($services -contains $instance)) { $services += $instance }
        }
    }

    $devices = @()
    foreach ($service in $services) {
        # Resolve the instance to host:port using dns-sd
        $resolveProc = Start-Process $dnsSd -ArgumentList "-L `"$service`" _adb-tls-connect._tcp local" -NoNewWindow -RedirectStandardOutput $resolveFile -PassThru
        Start-Sleep 2
        Stop-Process $resolveProc -Force

        $resolveLines = Get-Content $resolveFile
        foreach ($r in $resolveLines) {
            if ($r -match "can be reached at (.+?):(\d+)") {
                $device = [PSCustomObject]@{
                    Name = $service
                    Hostname = $matches[1]
                    Port = $matches[2]
                }
                $devices += $device
            }
        }
    }

    Remove-Item $resolveFile -ErrorAction SilentlyContinue
    return $devices
}

# -------------------------
# Resolve .local hostname to IPv4 using temp-file approach
# -------------------------
function Resolve-MDNSHostToIPv4 {
    param(
        [string]$hostname,
        [int]$timeoutSeconds = 5
    )

    if (-not $hostname.EndsWith(".")) { $hostname += "." }

    $dnsSd = "dns-sd.exe"
    $resolveFile = [IO.Path]::GetTempFileName()

    $proc = Start-Process $dnsSd -ArgumentList "-G v4 $hostname" `
        -NoNewWindow -RedirectStandardOutput $resolveFile -PassThru

    $resolvedIP = $null
    $stopWatch = [Diagnostics.Stopwatch]::StartNew()

    while ($stopWatch.Elapsed.TotalSeconds -lt $timeoutSeconds -and -not $resolvedIP) {
        Start-Sleep -Milliseconds 200
        if (Test-Path $resolveFile) {
            $lines = Get-Content $resolveFile -ErrorAction SilentlyContinue
            foreach ($line in $lines) {
                if ($line -match '\b(\d{1,3}(?:\.\d{1,3}){3})\b') {
                    $resolvedIP = $Matches[1]
                    break
                }
            }
        }
    }

    try { Stop-Process -Id $proc.Id -ErrorAction SilentlyContinue } catch {}
    Remove-Item $resolveFile -ErrorAction SilentlyContinue

    if (-not $resolvedIP) {
        Write-Warning "mDNS resolution timed out for $hostname"
    }

    return $resolvedIP
}

# -------------------------
# Connection management
# -------------------------
$DevicePortCache = @{}

function Get-ConnectedPortForIp {
    param([string]$ip)
    $out = adb devices
    foreach ($line in $out) {
        if ($line -match "^\s*($ip):(\d+)\s+device") { return $Matches[2] }
    }
    return $null
}

function Ensure-DeviceConnected {
    param([object]$device)

    $ip = $device.ip
    $existingPort = Get-ConnectedPortForIp -ip $ip
    if ($existingPort) {
        $DevicePortCache[$device.name] = $existingPort
        return "$ip`:$existingPort"
    }

    # Get advertised services (may include multiple ports)
    $mdnsDevices = Get-ADBDevicesViaMDNS -AutoConnect:$false
    foreach ($mdnsDevice in $mdnsDevices) {
        # Resolve hostname to IPv4
        $resolvedIP = Resolve-MDNSHostToIPv4 $mdnsDevice.Hostname 5
        if ($resolvedIP -ne $ip) { continue }

        $port = $mdnsDevice.Port
        Write-Host "Trying ${ip}:${port}..."
        adb connect "${ip}`:${port}" | Out-Null

        if ($LASTEXITCODE -eq 0 -and (Get-ConnectedPortForIp -ip $ip)) {
            Write-Host "Successfully connected to ${ip}:${port}"
            $DevicePortCache[$device.name] = $port
            return "${ip}`:${port}"
        } else {
            Write-Warning "Port ${port} did not respond, trying next advertised port..."
        }
    }

    # Fallback: manual input
    while ($true) {
        $port = Read-Host "Enter ADB port for $($device.name) at $ip"
        if ([string]::IsNullOrWhiteSpace($port)) { throw "Connection aborted for $($device.name)" }
        adb connect "$ip`:$port" | Out-Null
        if ($LASTEXITCODE -eq 0 -and (Get-ConnectedPortForIp -ip $ip)) { 
            $DevicePortCache[$device.name] = $port
            return "$ip`:$port"
        }
        Write-Warning "Connection failed."
    }
}

# -------------------------
# adbsync execution
# -------------------------
function Build-ExcludeArgs { 
    param([string[]]$excludeList)
    $args = @()
    foreach ($item in $excludeList) { $args += @("--exclude", $item) }
    return $args
}

function Run-AdbSync {
    param(
        [string]$direction,   # "pull" or "push"
        [string]$serial,      # ip:port
        [string]$sourcePath,
        [string]$destPath,
        [string[]]$excludeList,
        [string]$logFile,
        [switch]$delete
    )

    $excludeArgs = Build-ExcludeArgs -excludeList $excludeList
    $args = @("--adb-option", "s", $serial, "--show-progress", "-q") + $excludeArgs
    if ($delete) { $args += "--del" }
    $args += @($direction, "`"$sourcePath`"", "`"$destPath`"")

    Write-Host "Running: adbsync $($args -join ' ')"
    Add-Content -Path $logFile -Value "[$(Get-Date -Format o)] CMD: adbsync $($args -join ' ')"

    $tempOut = [System.IO.Path]::GetTempFileName()
    $tempErr = [System.IO.Path]::GetTempFileName()
    $proc = Start-Process -FilePath "adbsync.exe" -ArgumentList $args -NoNewWindow -Wait -PassThru -RedirectStandardOutput $tempOut -RedirectStandardError $tempErr
    $output = (Get-Content $tempOut -Raw) + "`n" + (Get-Content $tempErr -Raw)
    Remove-Item $tempOut, $tempErr -ErrorAction SilentlyContinue

    if ($proc.ExitCode -eq 0 -or $output -match "file (pulled|pushed|skipped)") {
        Add-Content -Path $logFile -Value "[$(Get-Date -Format o)] SUCCESS`n$output"
        return
    }

    Add-Content -Path $logFile -Value "[$(Get-Date -Format o)] ERROR`n$output"
    throw "adbsync exited with code $($proc.ExitCode)`n$output"
}

# -------------------------
# Merge per-device folder -> master (Unison)
# -------------------------
function Merge-ToMaster {
    param([string]$fromPath, [string]$masterPath, [string]$logFile)
    Ensure-Folder $masterPath
    Write-Host "Merging $fromPath -> $masterPath"
    unison $masterPath $fromPath -batch -prefer newer | Out-File -Append $logFile
}

# -------------------------
# Main syncing
# -------------------------
$devices  = Load-Json $devicesPath
$projects = Load-Json $projectsPath
Ensure-Folder $logsRoot

foreach ($project in $projects.projects) {
    Write-Host "`n=== Project: $($project.name) ==="
    $projectRoot = Join-Path $projects.projectsDirectory $project.name
    Ensure-Folder $projectRoot
    $masterPath = Join-Path $projectRoot "master"
    Ensure-Folder $masterPath
    $projectLogDir = Join-Path $logsRoot $project.name
    Ensure-Folder $projectLogDir

    $excludeList = @()
    if ($project.exclude) { $excludeList = $project.exclude }

    # ---- PULL from devices -> mirrors, merge -> master ----
    foreach ($pd in $project.devices) {
        $device = Get-DeviceByName $devices $pd.deviceName
        $serial = Ensure-DeviceConnected $device
        $deviceMirrorPath = Join-Path $projectRoot $device.name
        Ensure-Folder $deviceMirrorPath
        $logFile = Join-Path $projectLogDir ("{0}_{1}_pull.log" -f $project.name, $device.name)

        Write-Host "Syncing $($device.name) ($serial)"
        Write-Host "Pulling..."
        $remotePathForPull = Normalize-PathForContents $pd.remotePath
        Run-AdbSync -direction "pull" -serial $serial -sourcePath $remotePathForPull -destPath $deviceMirrorPath -excludeList $excludeList -logFile $logFile -delete
        Write-Host "Merging into master..."
        Merge-ToMaster $deviceMirrorPath $masterPath $logFile
    }

    # ---- PUSH from master -> all devices ----
    foreach ($pd in $project.devices) {
        $device = Get-DeviceByName $devices $pd.deviceName
        $serial = Ensure-DeviceConnected $device
        $logFile = Join-Path $projectLogDir ("{0}_{1}_push.log" -f $project.name, $device.name)

        Write-Host "Pushing master -> $($device.name)..."
        $sourcePathForPush = Normalize-PathForContents $masterPath
        $destPathForPush   = Normalize-PathForContents $pd.remotePath
        Run-AdbSync -direction "push" -serial $serial -sourcePath $sourcePathForPush -destPath $destPathForPush -excludeList $excludeList -logFile $logFile -delete
    }
}

Write-Host "`nAll projects synced."