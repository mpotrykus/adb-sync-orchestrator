# simple cache for resolved device ports
$script:DevicePortCache = @{}

function Get-ConnectedPortForIp {
    param([string]$ip)
    $lines = adb devices 2>$null | Select-Object -Skip 1
    foreach ($l in $lines) {
        if ($l -match "^\s*($ip):(\d+)\s+device") {
            return $Matches[2]
        }
    }
    return $null
}

function Ensure-ADBServer {
    try {
        # This is safe to call even if the server is already running
        adb start-server | Out-Null
    }
    catch {
        throw "Failed to start ADB server: $_"
    }
}

function Ensure-DeviceConnected {
    param([object]$device)

    Ensure-ADBServer

    $ip = $device.ip
    if (-not $ip) {
        # legacy: if serial present, return as-is
        return $device.serial
    }

    if ($script:DevicePortCache.ContainsKey($device.name)) {
        return "${ip}:$($script:DevicePortCache[$device.name])"
    }

    $existingPort = Get-ConnectedPortForIp -ip $ip
    if ($existingPort) {
        $script:DevicePortCache[$device.name] = $existingPort
        return "${ip}:$existingPort"
    }

    $mdnsDevices = Get-ADBDevicesViaMDNS
    foreach ($mdnsDevice in $mdnsDevices) {
        $resolvedIP = Resolve-MDNSHostToIPv4 $mdnsDevice.Hostname 5
        if ($resolvedIP -ne $ip) { continue }

        $port = $mdnsDevice.Port
        Write-Host "Trying ${ip}:${port}..."
        adb connect "${ip}:${port}" | Out-Null

        if ($LASTEXITCODE -eq 0 -and (Get-ConnectedPortForIp -ip $ip)) {
            Write-Host "Successfully connected to ${ip}:${port}"
            $script:DevicePortCache[$device.name] = $port
            return "${ip}:${port}"
        } else {
            Write-Warning "Port ${port} did not respond, trying next advertised port..."
        }
    }

    # Do not prompt when running headless
    if ($global:Headless) {
        throw "Headless mode: no interactive prompt available to get ADB port for $($device.name) at $ip"
    }

    while ($true) {
        $port = Read-Host "Enter ADB port for $($device.name) at $ip"
        if ([string]::IsNullOrWhiteSpace($port)) { throw "Connection aborted for $($device.name)" }
        adb connect "${ip}:${port}" | Out-Null
        if ($LASTEXITCODE -eq 0 -and (Get-ConnectedPortForIp -ip $ip)) {
            $script:DevicePortCache[$device.name] = $port
            return "${ip}:${port}"
        }
        Write-Warning "Connection failed."
    }
}

function Test-AndroidAppRunning {
    param([string]$serial, [string]$package)

    if ([string]::IsNullOrWhiteSpace($package)) { return $false }

    try {
        $proc = adb -s $serial shell pidof $package 2>$null
        if ($proc) {
            Write-Host "App $package is running on $serial - skipping sync."
            return $true
        }
    }
    catch {
        # ignore adb errors
    }
    return $false
}

function Get-StagingPath {
    param([string]$projectRoot, [string]$deviceName)
    $p = Join-Path (Get-ProjectStagingRoot $projectRoot) $deviceName
    Test-Folder $p
    return $p
}
