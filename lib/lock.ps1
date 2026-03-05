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
    param([string]$projectRoot, [int]$maxLockAgeHr = 4)

    $lockFile = Get-ProjectLockPath $projectRoot

    if (Test-Path $lockFile) {
        $age = (Get-Date) - (Get-Item $lockFile).LastWriteTime
        if ($age.TotalHours -lt $maxLockAgeHr) {
            Write-Host "Another sync appears to be running for project $projectRoot. Skipping."
            return $false
        }

        Write-Warning "Stale lock detected for $projectRoot. Recovering..."
        Remove-Item (Get-ProjectStagingRoot $projectRoot) -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $lockFile -Force
        Test-Folder (Get-ProjectStagingRoot $projectRoot)
    }

@"
pid=$PID
start=$(Get-Date -Format o)
"@ | Set-Content $lockFile

    return $true
}

function Remove-SyncLock {
    param([string]$projectRoot)
    $lockFile = Get-ProjectLockPath $projectRoot
    if (Test-Path $lockFile) { Remove-Item $lockFile -Force }
}
