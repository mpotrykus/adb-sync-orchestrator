if (-not ("System.Windows.Forms.NotifyIcon" -as [type])) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
}

function New-TrayIcon {
    param(
        [string]$IconPath,
        [string]$Tooltip = "My PowerShell Tray Tooltip",
        [switch]$MakeGlobal
    )
    $global:TrayIconTimeout = 0

    $icon = New-Object System.Windows.Forms.NotifyIcon

    # prefer explicit IconPath, else fall back to assets\connect.ico, else system info icon
    if ($IconPath -and (Test-Path $IconPath)) {
        $icon.Icon = New-Object System.Drawing.Icon($IconPath)
    }
    else {
        $defaultConnect = Join-Path $PSScriptRoot 'assets\connect.ico'
        if (Test-Path $defaultConnect) {
            try { $icon.Icon = New-Object System.Drawing.Icon($defaultConnect) } catch { $icon.Icon = [System.Drawing.SystemIcons]::Information }
        } else {
            $icon.Icon = [System.Drawing.SystemIcons]::Information
        }
    }

    $icon.Text = $Tooltip
    $icon.Visible = $true

    $contextMenu = New-Object System.Windows.Forms.ContextMenu
    $menuItem = New-Object System.Windows.Forms.MenuItem("Exit", {
        $icon.Dispose()
        [System.Windows.Forms.Application]::ExitThread()
    })

    $contextMenu.MenuItems.Add($menuItem)
    $icon.ContextMenu = $contextMenu

    if ($MakeGlobal) {
        $global:TrayIcon = $icon
        if (-not ($global:TrayIconTimeout -is [int])) { $global:TrayIconTimeout = 0 }
    }
}

function Show-TrayBalloon {
    param(
        [string]$Title = "Title",
        [string]$Message = "Message",
        [int]$TimeoutMs = 5000,
        [ValidateSet('None','Info','Warning','Error')][string]$IconType = 'Info'
    )

    if (-not $global:TrayIcon) { throw "Tray icon not created. Call New-TrayIcon first." }

    try {
        $enumVal = [System.Enum]::Parse([System.Windows.Forms.ToolTipIcon], $IconType)
    } catch {
        $enumVal = [System.Windows.Forms.ToolTipIcon]::Info
    }

    $origIcon = $global:TrayIcon.Icon
    
    try {
        switch ($enumVal) {
            ([System.Windows.Forms.ToolTipIcon]::Info)    { $null = ($global:TrayIcon.Icon = [System.Drawing.SystemIcons]::Information) }
            ([System.Windows.Forms.ToolTipIcon]::Warning) { $null = ($global:TrayIcon.Icon = [System.Drawing.SystemIcons]::Warning) }
            ([System.Windows.Forms.ToolTipIcon]::Error)   { $null = ($global:TrayIcon.Icon = [System.Drawing.SystemIcons]::Error) }
            default                                       { $null = ($global:TrayIcon.Icon = $origIcon) }
        }

        [void] $global:TrayIcon.ShowBalloonTip($TimeoutMs, $Title, $Message, $enumVal)
    } finally {
        #$null = ($global:TrayIcon.Icon = $origIcon)
    }

    return $null
}

function Close-TrayIcon {
    if ($global:TrayIcon) {
        try { $global:TrayIcon.Dispose() } catch {}
        Remove-Variable -Name TrayIcon -Scope Global -ErrorAction SilentlyContinue
    }
}

function Update-TrayTooltip {
    param(
        [string]$Tooltip
    )

    if (-not $global:TrayIcon) { throw "Tray icon not created. Call New-TrayIcon first." }

    $global:TrayIcon.Text = $Tooltip
    $global:TrayIcon.Visible = $true
}

# Set the tray icon based on a named stage. Looks for .ico files in ./assets by default.
function Set-TrayIconStage {
    param(
        [ValidateSet('connect','pull','merge','push','success','error','default')][string]$Stage = 'default',
        [string]$AssetsDir = (Join-Path $PSScriptRoot 'assets')
    )

    if (-not $global:TrayIcon) { return }

    $fileName = switch ($Stage) {
        'connect'  { 'connect.ico' }
        'pull'     { 'pull.ico' }
        'merge'    { 'merge.ico' }
        'push'     { 'push.ico' }
        'success'  { 'success.ico' }
        'error'    { 'error.ico' }
        default    { 'connect.ico' }
    }

    $path = Join-Path $AssetsDir $fileName
    if (Test-Path $path) {
        try {
            $global:TrayIcon.Icon = New-Object System.Drawing.Icon($path)
            $global:TrayIcon.Visible = $true
        } catch {
            # ignore icon swap failures
        }
    }
}