function Manage-Error {
    param(
        [string]$Message,
        [string]$ExceptionMessage,
        [switch]$ShowNotification
    )
    
    if ($ShowNotification) {
        Show-TrayBalloon -Title "ADB Sync: ERROR" -Message $Message -TimeoutMs 3000 -IconType "Error"
    }

    if ($ExceptionMessage) { $Message += ": $ExceptionMessage" }
    Write-Warning $Message
}

function Manage-Info {
    param(
        [string]$Message,
        [switch]$ShowNotification
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

    if ($ShowNotification) {
        Show-TrayBalloon -Title $title -Message $Message -TimeoutMs 3000 -IconType "Info"
    }
    
    Write-Host $Message
}
