# stop-local.ps1 — Stop all natively-running Day 23 observability services

$PIDS = "$PSScriptRoot\local-pids"

if (-not (Test-Path $PIDS)) {
    Write-Host "No PID directory found. Are services running?" -ForegroundColor Yellow
    exit 0
}

foreach ($pidFile in Get-ChildItem "$PIDS\*.pid") {
    $name = $pidFile.BaseName
    $pid  = [int](Get-Content $pidFile -ErrorAction SilentlyContinue)
    if ($pid -gt 0) {
        try {
            Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue
            Write-Host "  [stopped] $name  PID=$pid" -ForegroundColor Green
        } catch {
            Write-Host "  [skip] $name  PID=$pid not found (already stopped?)" -ForegroundColor DarkGray
        }
    }
    Remove-Item $pidFile -ErrorAction SilentlyContinue
}
Write-Host "`nAll services stopped." -ForegroundColor Yellow
