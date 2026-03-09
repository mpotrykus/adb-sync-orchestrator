function New-ExcludeArgs {
    param([string[]]$excludeList)
    $args = @()
    foreach ($item in $excludeList) {
        $args += @("--exclude", $item)
    }
    return $args
}

function Invoke-AdbSync {
    param(
        [string]$direction,
        [string]$serial,
        [string]$sourcePath,
        [string]$destPath,
        [string[]]$excludeList,
        [string]$logFile,
        [switch]$delete
    )

    $excludeArgs = New-ExcludeArgs -excludeList $excludeList
    $args = @("--adb-option", "s", $serial, "--show-progress", "-q") + $excludeArgs
    if ($delete) { $args += "--del" }
    $args += @($direction, $sourcePath, $destPath)

    # Quote any argument that contains whitespace so the spawned process sees it as one arg
    $argList = $args | ForEach-Object {
        if ($_ -match '\s') { '"' + ($_ -replace '"','\"') + '"' } else { $_ }
    }

    Write-Host "Running: adbsync $($argList -join ' ')"

    $tempOut = [System.IO.Path]::GetTempFileName()
    $tempErr = [System.IO.Path]::GetTempFileName()

    $proc = Start-Process -FilePath "adbsync.exe" -ArgumentList $argList -NoNewWindow -Wait -PassThru -RedirectStandardOutput $tempOut -RedirectStandardError $tempErr

    $output = (Get-Content $tempOut -Raw) + "`n" + (Get-Content $tempErr -Raw)
    Remove-Item $tempOut, $tempErr -ErrorAction SilentlyContinue

    if ($proc.ExitCode -eq 0 -or $output -match "file (pulled|pushed|skipped)") {
        Add-Content $logFile $output
        return
    }

    throw "adbsync failed`n$output"
}

function Merge-ToMaster {
    param([string]$fromPath, [string]$masterPath, [string]$logFile)
    Test-Folder $masterPath
    Write-Host "Merging $fromPath -> $masterPath"
    unison $masterPath $fromPath -batch -prefer newer | Out-File -Append $logFile
}
