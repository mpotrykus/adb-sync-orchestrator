function Get-ProjectStagingRoot {
    param([string]$projectRoot)
    $p = Join-Path $projectRoot ".sync_staging"
    Test-Folder $p
    return $p
}

function Get-ProjectLockPath {
    param([string]$projectRoot)
    return Join-Path (Get-ProjectStagingRoot $projectRoot) ".sync_lock"
}

function Get-SyncLock {
    param(
        [string]$projectRoot,
        [int]$maxLockAgeHours = 4
    )

    $stagingRoot = Get-ProjectStagingRoot $projectRoot
    $lockFile = Get-ProjectLockPath $projectRoot

    # helper to create a new lock
    function New-Lock {
        Test-Folder $stagingRoot
@"
pid=$PID
start=$(Get-Date -Format o)
"@ | Set-Content -Path $lockFile -Encoding UTF8
        return $true
    }

    # read lock file if present (fail-safe)
    $lockContent = $null
    if (Test-Path $lockFile) {
        try {
            $lockContent = Get-Content $lockFile -Raw -ErrorAction Stop
        } catch {
            Manage-Info "Unable to read lock file. Removing corrupt lock..."
            if (Test-Path $lockFile) { Remove-Item $lockFile -Force -ErrorAction SilentlyContinue }
            if (Test-Path $stagingRoot) { Remove-Item $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue }
            Test-Folder $stagingRoot
            $lockContent = $null
        }
    }

    if (-not $lockContent) { return New-Lock }

    # validate pid entry
    if (-not ($lockContent -match 'pid=(\d+)')) {
        Manage-Info "Lock file is invalid. Removing lock for resume..."
        if (Test-Path $lockFile) { Remove-Item $lockFile -Force -ErrorAction SilentlyContinue }
        Test-Folder $stagingRoot
        return New-Lock
    }

    $lockPid = [int]$matches[1]

    # try parse start time (optional)
    $lockStart = $null
    if ($lockContent -match 'start=(.+)') {
        try { $lockStart = [datetime]::Parse($matches[1].Trim()) } catch { $lockStart = $null }
    }

    # expire locks older than 4 hours
    if ($lockStart) {
        $age = (Get-Date) - $lockStart
        if ($age.TotalHours -gt $maxLockAgeHours) {
            Manage-Info ("Lock held by PID {0} expired (age: {1:N2}h). Recovering lock..." -f $lockPid, $age.TotalHours)
            if (Test-Path $stagingRoot) { Remove-Item $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue }
            if (Test-Path $lockFile) { Remove-Item $lockFile -Force -ErrorAction SilentlyContinue }
            Test-Folder $stagingRoot
            return New-Lock
        }
    }

    # check process
    $proc = Get-Process -Id $lockPid -ErrorAction SilentlyContinue
    if (-not $proc) {
        Manage-Info "Lock held by PID $lockPid which is not running. Recovering lock..."
        if (Test-Path $stagingRoot) { Remove-Item $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue }
        if (Test-Path $lockFile) { Remove-Item $lockFile -Force -ErrorAction SilentlyContinue }
        Test-Folder $stagingRoot
        return New-Lock
    }

    # process is running; respect lock unless it's stale (already handled above)
    if ($lockStart) {

        Write-Host "Lock held by PID $lockPid. Respecting lock."
        return $false
    }

    Write-Host "Lock held by PID $lockPid; start time unparsable. Respecting lock."
    return $false
}

function Remove-SyncLock {
    param([string]$projectRoot)
    if ([string]::IsNullOrWhiteSpace($projectRoot)) { return }
    $lockFile = Get-ProjectLockPath $projectRoot
    if (Test-Path $lockFile) { Remove-Item $lockFile -Force }
}
