param(
    [string]$BaseDir = $PSScriptRoot,
    [int]$IntervalSec = 5
)

# Relaunch as STA if needed (required for WinForms)
if ($host.Runspace.ApartmentState -ne 'STA') {
    $cmd = Get-Command powershell.exe -ErrorAction SilentlyContinue
    if ($cmd) { $psExe = $cmd.Source } else { $psExe = "powershell.exe" }
    $scriptPath = $MyInvocation.MyCommand.Path
    Start-Process -FilePath $psExe -ArgumentList "-STA","-NoProfile","-ExecutionPolicy","Bypass","-File","`"$scriptPath`"","-BaseDir","`"$BaseDir`"","-IntervalSec",$IntervalSec -WindowStyle Hidden
    return
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Load projectsDirectory from projects.json if present
$projectsJson = Join-Path $BaseDir "projects.json"
$projectsDirectory = $BaseDir
if (Test-Path $projectsJson) {
    try {
        $pj = Get-Content $projectsJson -Raw | ConvertFrom-Json
        if ($pj.projectsDirectory) { $projectsDirectory = $pj.projectsDirectory }
    } catch {}
}

function Get-SyncLocks {
    param([string]$root)
    if (-not (Test-Path $root)) { return @() }
    return Get-ChildItem -Path $root -Recurse -Filter ".sync_lock" -ErrorAction SilentlyContinue
}

function Get-LastLogFile {
    param([string]$root)
    if (-not (Test-Path $root)) { return $null }
    $logs = Get-ChildItem -Path $root -Recurse -Include *.log -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
    return $logs | Select-Object -First 1
}

# Create notify icon and menu
$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Icon = [System.Drawing.SystemIcons]::Application
$notify.Text = "adbsync: initializing..."
$notify.Visible = $true

# Context menu
$menu = New-Object System.Windows.Forms.ContextMenuStrip

$miRun = New-Object System.Windows.Forms.ToolStripMenuItem "Run Sync Now"
$miExit = New-Object System.Windows.Forms.ToolStripMenuItem "Exit"

$menu.Items.Add($miRun) | Out-Null
$menu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new()) | Out-Null
$menu.Items.Add($miExit) | Out-Null

$notify.ContextMenuStrip = $menu

# Actions
$miRun.Add_Click({
    try {
        $syncPath = Join-Path $BaseDir "sync.ps1"
        if (-not (Test-Path $syncPath)) {
            [System.Windows.Forms.MessageBox]::Show("sync.ps1 not found at $syncPath","adbsync")
            return
        }
        Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile","-ExecutionPolicy","Bypass","-NoExit","-File","`"$syncPath`"" -WorkingDirectory $BaseDir
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Failed to start sync: $_","adbsync")
    }
})

$miExit.Add_Click({
    $timer.Stop()
    $notify.Visible = $false
    $notify.Dispose()
    [System.Windows.Forms.Application]::Exit()
})

# Tooltip/status updater
function Update-Status {
    $locks = Get-SyncLocks -root $projectsDirectory
    if ($locks.Count -eq 0) {
        $notify.Icon = [System.Drawing.SystemIcons]::Application
        $notify.Text = "Idle"
    } else {
        $first = $locks[0]
        $proj = Split-Path $first.DirectoryName -Leaf
        $parentPath = Split-Path $first.DirectoryName -Parent
        $projParent = if ($parentPath) { Split-Path $parentPath -Leaf } else { "" }

        $notify.Icon = [System.Drawing.SystemIcons]::Information
        if ($projParent) {
            $notify.Text = "Syncing '$projParent' (+$($locks.Count - 1) more)"
        } else {
            $notify.Text = "Syncing '$proj' (+$($locks.Count - 1) more)"
        }
    }
}

# Initial update
Update-Status

# Timer to poll status
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = [int]($IntervalSec * 1000)
$timer.Add_Tick({ Update-Status })
$timer.Start()

# Double-click to open logs folder
$notify.Add_MouseDoubleClick({
    if (Test-Path $projectsDirectory) { Start-Process explorer.exe $projectsDirectory }
})

# Run message loop (keeps script alive)
[System.Windows.Forms.Application]::Run()
