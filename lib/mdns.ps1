function Get-ADBDevicesViaMDNS {
    param()
    $dnsSd = "dns-sd.exe"
    $browseFile = [IO.Path]::GetTempFileName()
    $resolveFile = [IO.Path]::GetTempFileName()
    $services = @()

    $browseProc = Start-Process $dnsSd -ArgumentList "-B _adb-tls-connect._tcp local" -NoNewWindow -RedirectStandardOutput $browseFile -PassThru
    Start-Sleep 3
    Stop-Process $browseProc -Force

    $browseLines = Get-Content $browseFile -ErrorAction SilentlyContinue
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
        $resolveProc = Start-Process $dnsSd -ArgumentList "-L `"$service`" _adb-tls-connect._tcp local" -NoNewWindow -RedirectStandardOutput $resolveFile -PassThru
        Start-Sleep 2
        Stop-Process $resolveProc -Force

        $resolveLines = Get-Content $resolveFile -ErrorAction SilentlyContinue
        foreach ($r in $resolveLines) {
            if ($r -match "can be reached at (.+?):(\d+)") {
                $device = [PSCustomObject]@{
                    Name     = $service
                    Hostname = $matches[1]
                    Port     = $matches[2]
                }
                $devices += $device
            }
        }
    }

    Remove-Item $resolveFile -ErrorAction SilentlyContinue
    return $devices
}

function Resolve-MDNSHostToIPv4 {
    param([string]$hostname, [int]$timeoutSeconds = 5)
    if (-not $hostname.EndsWith(".")) { $hostname += "." }

    $dnsSd = "dns-sd.exe"
    $resolveFile = [IO.Path]::GetTempFileName()

    $proc = Start-Process $dnsSd -ArgumentList "-G v4 $hostname" -NoNewWindow -RedirectStandardOutput $resolveFile -PassThru

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

    if (-not $resolvedIP) { Write-Warning "mDNS resolution timed out for $hostname" }
    return $resolvedIP
}
