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
