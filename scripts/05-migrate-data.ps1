# ===========================================
# 05-migrate-data.ps1 - Robocopy migration script
# Run this script on a Windows machine with access to both shares
# ===========================================

param(
    [Parameter(Mandatory=$false)]
    [string]$Source,

    [Parameter(Mandatory=$false)]
    [string]$Destination,

    [Parameter(Mandatory=$false)]
    [string]$ServerName,

    [Parameter(Mandatory=$false)]
    [string]$ShareName = "Shared",

    [Parameter(Mandatory=$false)]
    [int]$Threads = 32,

    [Parameter(Mandatory=$false)]
    [switch]$WhatIf
)

Write-Host "=== File Server Migration Script ===" -ForegroundColor Cyan
Write-Host ""

# If parameters not provided, prompt for them
if (-not $Source) {
    $Source = Read-Host "Enter source path (e.g., E:\OldFileShare or \\oldserver\share)"
}

if (-not $ServerName -and -not $Destination) {
    $ServerName = Read-Host "Enter new server name or IP (e.g., prox-fileserv or 10.0.0.50)"
}

if (-not $Destination) {
    $Destination = "\\$ServerName\$ShareName"
}

Write-Host ""
Write-Host "Migration Configuration:" -ForegroundColor Yellow
Write-Host "  Source:      $Source"
Write-Host "  Destination: $Destination"
Write-Host "  Threads:     $Threads"
Write-Host ""

# Verify source exists
if (-not (Test-Path $Source)) {
    Write-Host "ERROR: Source path does not exist: $Source" -ForegroundColor Red
    exit 1
}

# Test destination connectivity
Write-Host "Testing destination connectivity..."
try {
    $testPath = Test-Path $Destination -ErrorAction Stop
    if ($testPath) {
        Write-Host "  Destination accessible" -ForegroundColor Green
    }
} catch {
    Write-Host "ERROR: Cannot access destination: $Destination" -ForegroundColor Red
    Write-Host "Ensure you have network access and permissions to the share."
    Write-Host ""
    Write-Host "You may need to map the drive first:"
    Write-Host "  net use Z: $Destination"
    exit 1
}

# Get source statistics
Write-Host ""
Write-Host "Analyzing source..."
$sourceItems = Get-ChildItem -Path $Source -Recurse -ErrorAction SilentlyContinue
$fileCount = ($sourceItems | Where-Object { -not $_.PSIsContainer }).Count
$folderCount = ($sourceItems | Where-Object { $_.PSIsContainer }).Count
$totalSize = ($sourceItems | Where-Object { -not $_.PSIsContainer } | Measure-Object -Property Length -Sum).Sum
$totalSizeGB = [math]::Round($totalSize / 1GB, 2)

Write-Host "  Files:   $fileCount"
Write-Host "  Folders: $folderCount"
Write-Host "  Size:    $totalSizeGB GB"
Write-Host ""

# Confirm before proceeding
if ($WhatIf) {
    Write-Host "WhatIf mode - showing what would be copied..." -ForegroundColor Yellow
    $robocopyArgs = @(
        $Source,
        $Destination,
        "/MIR",
        "/COPY:DAT",
        "/MT:$Threads",
        "/R:3",
        "/W:1",
        "/L",  # List only
        "/NP"
    )
} else {
    $confirm = Read-Host "Proceed with migration? [y/N]"
    if ($confirm -ne 'y' -and $confirm -ne 'Y') {
        Write-Host "Aborted."
        exit 0
    }

    $logFile = "migration_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
    Write-Host ""
    Write-Host "Starting migration..." -ForegroundColor Green
    Write-Host "Log file: $logFile"
    Write-Host ""

    $robocopyArgs = @(
        $Source,
        $Destination,
        "/MIR",
        "/COPY:DAT",
        "/MT:$Threads",
        "/R:3",
        "/W:1",
        "/LOG:$logFile",
        "/TEE",
        "/NP"
    )
}

# Execute robocopy
$startTime = Get-Date
& robocopy @robocopyArgs
$exitCode = $LASTEXITCODE
$endTime = Get-Date
$duration = $endTime - $startTime

Write-Host ""
Write-Host "=== Migration Summary ===" -ForegroundColor Cyan

# Interpret robocopy exit codes
$exitMessages = @{
    0 = "No files were copied. No failure was encountered."
    1 = "All files were copied successfully."
    2 = "Extra files or directories detected. No files copied."
    3 = "Some files were copied. Additional files were present."
    4 = "Mismatched files or directories detected."
    5 = "Some files were copied. Some files were mismatched."
    6 = "Additional and mismatched files exist."
    7 = "Files were copied, mismatched, and additional files present."
    8 = "Several files did not copy."
}

if ($exitCode -lt 8) {
    Write-Host "Status: SUCCESS" -ForegroundColor Green
} else {
    Write-Host "Status: COMPLETED WITH ERRORS" -ForegroundColor Yellow
}

Write-Host "Exit Code: $exitCode"
if ($exitMessages.ContainsKey($exitCode)) {
    Write-Host "Message: $($exitMessages[$exitCode])"
}
Write-Host "Duration: $($duration.ToString('hh\:mm\:ss'))"

if (-not $WhatIf) {
    Write-Host ""
    Write-Host "Log file saved to: $logFile"
}

Write-Host ""
Write-Host "=== Migration Complete ===" -ForegroundColor Cyan
