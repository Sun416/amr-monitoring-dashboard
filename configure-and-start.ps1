$ErrorActionPreference = 'Stop'

$projectDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$envPath = Join-Path $projectDirectory '.env'
$webUrl = 'http://127.0.0.1:3080'

function Set-EnvironmentValue {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Value
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    if (Test-Path -LiteralPath $envPath) {
        Get-Content -LiteralPath $envPath | ForEach-Object { [void]$lines.Add($_) }
    }

    $replacement = $Name + '=' + $Value
    $updated = $false
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -match ('^\s*' + [regex]::Escape($Name) + '\s*=')) {
            $lines[$index] = $replacement
            $updated = $true
            break
        }
    }

    if (-not $updated) {
        [void]$lines.Add($replacement)
    }

    $utf8WithoutBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllLines($envPath, $lines, $utf8WithoutBom)
}

Write-Host ''
Write-Host 'AMR Web database configuration' -ForegroundColor Cyan
Write-Host 'Server   : 12.1.2.61:1433'
Write-Host 'Database : IOT2020'
Write-Host 'User     : automation'
Write-Host ''

$securePassword = Read-Host 'Enter the SQL Server password (input is hidden)' -AsSecureString
if ($securePassword.Length -eq 0) {
    Write-Host 'Password was empty. Configuration cancelled.' -ForegroundColor Yellow
    Read-Host 'Press Enter to close'
    exit 1
}

$passwordPointer = [IntPtr]::Zero
$plainPassword = $null
try {
    $passwordPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
    $plainPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($passwordPointer)
    $escapedPassword = $plainPassword.Replace('\', '\\').Replace('"', '\"').Replace("`r", '\r').Replace("`n", '\n')
    Set-EnvironmentValue -Name 'DB_PASSWORD' -Value ('"' + $escapedPassword + '"')
}
finally {
    $plainPassword = $null
    $securePassword.Dispose()
    if ($passwordPointer -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordPointer)
    }
}

$listener = Get-NetTCPConnection -LocalPort 3080 -State Listen -ErrorAction SilentlyContinue
if ($listener) {
    Write-Host "AMR Web is already listening on port 3080 (PID $($listener.OwningProcess))." -ForegroundColor Yellow
}
else {
    $nodeProcess = Start-Process `
        -FilePath 'node.exe' `
        -ArgumentList 'server.js' `
        -WorkingDirectory $projectDirectory `
        -WindowStyle Hidden `
        -PassThru
    Write-Host "AMR Web process started (PID $($nodeProcess.Id))." -ForegroundColor Green
}

$healthSucceeded = $false
$lastHealthError = $null
for ($attempt = 1; $attempt -le 15; $attempt++) {
    try {
        $health = Invoke-RestMethod -Uri ($webUrl + '/api/health') -Method Get -TimeoutSec 5
        if ($health.status -eq 'ok') {
            $healthSucceeded = $true
            break
        }
    }
    catch {
        $lastHealthError = $_.Exception.Message
        Start-Sleep -Seconds 1
    }
}

if ($healthSucceeded) {
    Write-Host ''
    Write-Host 'Database connection verified successfully.' -ForegroundColor Green
    Write-Host "Open: $webUrl" -ForegroundColor Cyan
    Start-Process $webUrl
}
else {
    Write-Host ''
    Write-Host 'The Web service started, but the database health check failed.' -ForegroundColor Red
    Write-Host 'Check the password and the DWS SELECT / procedure EXECUTE permissions.' -ForegroundColor Yellow
    if ($lastHealthError) {
        Write-Host $lastHealthError -ForegroundColor DarkGray
    }
}

Write-Host ''
Read-Host 'Press Enter to close this configuration window'

