function Manage-Error {
    param(
        [string]$Message,
        [string]$ExceptionMessage
    )
    Show-TrayBalloon -Title "ADB Sync: ERROR" -Message $Message -TimeoutMs 3000 -IconType "Error"
    if ($ExceptionMessage) { $Message += ": $ExceptionMessage" }
    Write-Warning $Message
}

function Manage-Info {
    param(
        [string]$Message
    )

    $title = "ADB Sync"
    try {
        $proj = $null
        if (Get-Variable -Name project -Scope Script -ErrorAction SilentlyContinue) {
            $proj = Get-Variable -Name project -Scope Script -ValueOnly -ErrorAction SilentlyContinue
        } elseif (Get-Variable -Name project -Scope Global -ErrorAction SilentlyContinue) {
            $proj = Get-Variable -Name project -Scope Global -ValueOnly -ErrorAction SilentlyContinue
        }
        if ($proj -and $proj.name) { $title = "ADB Sync ($($proj.name))" }
    } catch {}

    Show-TrayBalloon -Title $title -Message $Message -TimeoutMs 3000 -IconType "Info"
    Write-Host $Message
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