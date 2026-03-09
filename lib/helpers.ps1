function Import-Json {
    param([string]$path)
    if (!(Test-Path $path)) { throw "Missing JSON file: $path" }
    Get-Content $path -Raw | ConvertFrom-Json
}

function Test-Folder {
    param([string]$path)
    if (!(Test-Path $path)) { New-Item -ItemType Directory -Path $path | Out-Null }
}

function Get-DeviceByName {
    param($devices, [string]$name)
    $dev = $devices.devices | Where-Object { $_.name -eq $name }
    if (-not $dev) { throw "Device '$name' not found in devices.json" }
    return $dev
}

function Convert-PathForContents {
    param([string]$remotePath)
    if ($remotePath.EndsWith("/.")) {
        $remotePath = $remotePath.Substring(0, $remotePath.Length - 2)
    }
    $remotePath = $remotePath.TrimEnd('/')
    return "$remotePath/."
}

function Format-DurationHighestUnit {
    param(
        [object]$Duration,
        [datetime]$Start,
        [datetime]$End = (Get-Date)
    )

    # resolve TimeSpan
    if ($PSBoundParameters.ContainsKey('Start')) {
        $ts = $End - $Start
    } elseif ($Duration -is [timespan]) {
        $ts = $Duration
    } elseif ($Duration -is [datetime]) {
        $ts = (Get-Date) - $Duration
    } else {
        $sec = 0.0
        if ([double]::TryParse([string]$Duration, [ref]$sec)) {
            $ts = [timespan]::FromSeconds($sec)
        } else {
            throw "Format-DurationHighestUnit: unsupported Duration type"
        }
    }

    # choose highest non-zero unit and format
    if ($ts.TotalDays -ge 1) {
        $val = [math]::Round($ts.TotalDays,2)
        $unit = "day"
    } elseif ($ts.TotalHours -ge 1) {
        $val = [math]::Round($ts.TotalHours,2)
        $unit = "hour"
    } elseif ($ts.TotalMinutes -ge 1) {
        $val = [math]::Round($ts.TotalMinutes,2)
        $unit = "minute"
    } elseif ($ts.TotalSeconds -ge 1) {
        $val = [math]::Round($ts.TotalSeconds,2)
        $unit = "second"
    } else {
        $val = [math]::Round($ts.TotalMilliseconds)
        $unit = "ms"
    }

    if ($unit -eq "ms") {
        return "$val $unit"
    }

    if ($val -eq 1) { return "$val $unit" } else { return "$val ${unit}s" }
}