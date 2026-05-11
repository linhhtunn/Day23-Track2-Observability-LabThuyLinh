# start-local.ps1 — Run Day 23 observability stack natively on Windows (no Docker)
# Usage: .\start-local.ps1 [-SlackWebhook <url>]
# Requires: PowerShell 5+, internet access for first run

param(
    [string]$SlackWebhook = $env:SLACK_WEBHOOK_URL
)

$ErrorActionPreference = "Stop"
$LAB     = $PSScriptRoot
$BINS    = "$LAB\local-bins"
$DATA    = "$LAB\local-data"
$CONFIGS = "$LAB\local-configs"
$LOGS    = "$LAB\local-logs"
$PIDS    = "$LAB\local-pids"

foreach ($d in @($BINS, $DATA, $LOGS, $PIDS,
    "$DATA\prometheus", "$DATA\grafana",
    "$DATA\loki\chunks", "$DATA\loki\rules", "$DATA\loki\compactor")) {
    New-Item -ItemType Directory -Force -Path $d | Out-Null
}

# ── Helper: download + extract a zip ─────────────────────────────────────────
function Get-Binary($name, $url, $exePath) {
    if (Test-Path $exePath) {
        Write-Host "  [skip] $name already present" -ForegroundColor DarkGray
        return
    }
    Write-Host "  [download] $name ..." -ForegroundColor Cyan
    $zip = "$BINS\$name.zip"
    try {
        Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
        Expand-Archive -Path $zip -DestinationPath "$BINS\$name-tmp" -Force
        Remove-Item $zip -ErrorAction SilentlyContinue
        Write-Host "  [ok] $name" -ForegroundColor Green
    } catch {
        Write-Warning "Failed to download $name : $_"
    }
}

function Get-BinaryTar($name, $url, $exePath) {
    if (Test-Path $exePath) {
        Write-Host "  [skip] $name already present" -ForegroundColor DarkGray
        return
    }
    Write-Host "  [download] $name ..." -ForegroundColor Cyan
    $tar = "$BINS\$name.tar.gz"
    try {
        Invoke-WebRequest -Uri $url -OutFile $tar -UseBasicParsing
        & tar -xzf $tar -C "$BINS" 2>&1 | Out-Null
        Remove-Item $tar -ErrorAction SilentlyContinue
        Write-Host "  [ok] $name" -ForegroundColor Green
    } catch {
        Write-Warning "Failed to download $name : $_"
    }
}

# ── Download binaries ─────────────────────────────────────────────────────────
Write-Host "`n=== Downloading binaries (skipped if already present) ===" -ForegroundColor Yellow

# Prometheus
$promExe = "$BINS\prometheus-2.55.0.windows-amd64\prometheus.exe"
Get-Binary "prometheus" `
    "https://github.com/prometheus/prometheus/releases/download/v2.55.0/prometheus-2.55.0.windows-amd64.zip" `
    $promExe
if (-not (Test-Path $promExe)) {
    $promExe = (Get-ChildItem -Recurse "$BINS" -Filter "prometheus.exe" -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -notmatch "promtool" } | Select-Object -First 1)?.FullName
}

# Alertmanager
$amExe = "$BINS\alertmanager-0.27.0.windows-amd64\alertmanager.exe"
Get-Binary "alertmanager" `
    "https://github.com/prometheus/alertmanager/releases/download/v0.27.0/alertmanager-0.27.0.windows-amd64.zip" `
    $amExe
if (-not (Test-Path $amExe)) {
    $amExe = (Get-ChildItem -Recurse "$BINS" -Filter "alertmanager.exe" -ErrorAction SilentlyContinue |
                Select-Object -First 1)?.FullName
}

# Grafana
$grafanaExe = "$BINS\grafana-v11.3.0\bin\grafana-server.exe"
if (-not (Test-Path $grafanaExe)) {
    $grafanaExe = "$BINS\grafana-11.3.0\bin\grafana-server.exe"
}
Get-Binary "grafana" `
    "https://dl.grafana.com/oss/release/grafana-11.3.0.windows-amd64.zip" `
    $grafanaExe
if (-not (Test-Path $grafanaExe)) {
    $grafanaExe = (Get-ChildItem -Recurse "$BINS" -Filter "grafana-server.exe" -ErrorAction SilentlyContinue |
                   Select-Object -First 1)?.FullName
}

# Loki
$lokiExe = "$BINS\loki-windows-amd64.exe"
if (-not (Test-Path $lokiExe)) {
    Write-Host "  [download] loki ..." -ForegroundColor Cyan
    try {
        Invoke-WebRequest -Uri "https://github.com/grafana/loki/releases/download/v3.3.0/loki-windows-amd64.exe.zip" `
            -OutFile "$BINS\loki.zip" -UseBasicParsing
        Expand-Archive -Path "$BINS\loki.zip" -DestinationPath $BINS -Force
        Remove-Item "$BINS\loki.zip" -ErrorAction SilentlyContinue
        Write-Host "  [ok] loki" -ForegroundColor Green
    } catch { Write-Warning "Loki download failed: $_" }
}

# Jaeger all-in-one
$jaegerExe = (Get-ChildItem -Recurse "$BINS" -Filter "jaeger-all-in-one.exe" -ErrorAction SilentlyContinue |
              Select-Object -First 1)?.FullName
if (-not $jaegerExe) {
    Write-Host "  [download] jaeger ..." -ForegroundColor Cyan
    try {
        Invoke-WebRequest -Uri "https://github.com/jaegertracing/jaeger/releases/download/v1.62.0/jaeger-1.62.0-windows-amd64.tar.gz" `
            -OutFile "$BINS\jaeger.tar.gz" -UseBasicParsing
        & tar -xzf "$BINS\jaeger.tar.gz" -C $BINS 2>&1 | Out-Null
        Remove-Item "$BINS\jaeger.tar.gz" -ErrorAction SilentlyContinue
        $jaegerExe = (Get-ChildItem -Recurse "$BINS" -Filter "jaeger-all-in-one.exe" -ErrorAction SilentlyContinue |
                      Select-Object -First 1)?.FullName
        Write-Host "  [ok] jaeger" -ForegroundColor Green
    } catch { Write-Warning "Jaeger download failed: $_" }
}

# OTel Collector Contrib
$otelExe = (Get-ChildItem -Recurse "$BINS" -Filter "otelcol-contrib.exe" -ErrorAction SilentlyContinue |
             Select-Object -First 1)?.FullName
if (-not $otelExe) {
    Write-Host "  [download] otel-collector ..." -ForegroundColor Cyan
    try {
        Invoke-WebRequest -Uri "https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v0.114.0/otelcol-contrib_0.114.0_windows_amd64.tar.gz" `
            -OutFile "$BINS\otelcol.tar.gz" -UseBasicParsing
        & tar -xzf "$BINS\otelcol.tar.gz" -C $BINS 2>&1 | Out-Null
        Remove-Item "$BINS\otelcol.tar.gz" -ErrorAction SilentlyContinue
        $otelExe = (Get-ChildItem -Recurse "$BINS" -Filter "otelcol-contrib.exe" -ErrorAction SilentlyContinue |
                    Select-Object -First 1)?.FullName
        Write-Host "  [ok] otel-collector" -ForegroundColor Green
    } catch { Write-Warning "OTel Collector download failed: $_" }
}

# ── Prepare Grafana provisioning ──────────────────────────────────────────────
$dashboardsPath = "$LAB\02-prometheus-grafana\grafana\dashboards"
$localProvDir   = "$LAB\local-grafana-provisioning"
New-Item -ItemType Directory -Force -Path "$localProvDir\datasources"  | Out-Null
New-Item -ItemType Directory -Force -Path "$localProvDir\dashboards"   | Out-Null

Copy-Item "$CONFIGS\datasources.yml" "$localProvDir\datasources\datasources.yml" -Force

$dashCfg = (Get-Content "$CONFIGS\dashboards.yml") -replace "DASHBOARDS_PATH_PLACEHOLDER", ($dashboardsPath -replace "\\", "/")
$dashCfg | Set-Content "$localProvDir\dashboards\dashboards.yml" -Encoding utf8

# ── Start services ────────────────────────────────────────────────────────────
Write-Host "`n=== Starting services ===" -ForegroundColor Yellow

function Start-Svc($name, $exe, $args, $workDir, $env) {
    if (-not (Test-Path $exe)) {
        Write-Warning "Binary not found, skipping $name : $exe"
        return $null
    }
    $logFile = "$LOGS\$name.log"
    $pi = New-Object System.Diagnostics.ProcessStartInfo
    $pi.FileName = $exe
    $pi.Arguments = $args
    $pi.UseShellExecute = $false
    $pi.RedirectStandardOutput = $true
    $pi.RedirectStandardError = $true
    $pi.CreateNoWindow = $true
    if ($workDir) { $pi.WorkingDirectory = $workDir }
    if ($env) {
        foreach ($kv in $env.GetEnumerator()) {
            $pi.EnvironmentVariables[$kv.Key] = $kv.Value
        }
    }
    $proc = [System.Diagnostics.Process]::Start($pi)
    $proc.BeginOutputReadLine()
    $proc.BeginErrorReadLine()
    $proc.Id | Out-File "$PIDS\$name.pid"
    Write-Host "  [started] $name  PID=$($proc.Id)" -ForegroundColor Green
    return $proc
}

# 1. Jaeger (OTLP gRPC on 4320, UI on 16686)
$procs = @{}
if ($jaegerExe) {
    $jaegerArgs = "--collector.otlp.enabled=true --collector.otlp.grpc.host-port=:4320"
    $jaegerEnv  = @{ "COLLECTOR_OTLP_ENABLED" = "true" }
    $procs["jaeger"] = Start-Svc "jaeger" $jaegerExe $jaegerArgs $null $jaegerEnv
    Start-Sleep -Seconds 2
}

# 2. OTel Collector
if ($otelExe) {
    $procs["otel"] = Start-Svc "otel-collector" $otelExe "--config=$CONFIGS\otel-config.yaml" $null $null
    Start-Sleep -Seconds 2
}

# 3. Prometheus (with local config + rules)
if ($promExe -and (Test-Path $promExe)) {
    $rulesDir = "$LAB\02-prometheus-grafana\prometheus\rules"
    New-Item -ItemType Directory -Force -Path "$BINS\prom-run" | Out-Null
    # Copy config + rules into a working dir for prometheus
    $promRunCfg = "$BINS\prom-run\prometheus.yml"
    Copy-Item "$CONFIGS\prometheus.yml" $promRunCfg -Force
    $promRulesDir = "$BINS\prom-run\rules"
    if (-not (Test-Path $promRulesDir)) { New-Item -ItemType Directory -Force -Path $promRulesDir | Out-Null }
    Get-ChildItem "$rulesDir\*.yml" | ForEach-Object { Copy-Item $_.FullName "$promRulesDir\" -Force }
    $promArgs = "--config.file=$promRunCfg --storage.tsdb.path=$DATA\prometheus --web.enable-lifecycle --enable-feature=exemplar-storage"
    $procs["prometheus"] = Start-Svc "prometheus" $promExe $promArgs $null $null
    Start-Sleep -Seconds 2
}

# 4. Alertmanager
if ($amExe -and (Test-Path $amExe)) {
    $slackUrl = if ($SlackWebhook) { $SlackWebhook } else { "https://hooks.slack.com/services/REPLACE/ME" }
    $amEnv = @{ "SLACK_WEBHOOK_URL" = $slackUrl }
    $amArgs = "--config.file=$LAB\02-prometheus-grafana\alertmanager\alertmanager.yml --storage.path=$DATA\alertmanager"
    New-Item -ItemType Directory -Force -Path "$DATA\alertmanager" | Out-Null
    $procs["alertmanager"] = Start-Svc "alertmanager" $amExe $amArgs $null $amEnv
    Start-Sleep -Seconds 1
}

# 5. Loki
if ($lokiExe -and (Test-Path $lokiExe)) {
    $procs["loki"] = Start-Svc "loki" $lokiExe "-config.file=$CONFIGS\loki-config.yaml" $LAB $null
    Start-Sleep -Seconds 2
}

# 6. Grafana
if ($grafanaExe -and (Test-Path $grafanaExe)) {
    $grafanaHome = Split-Path (Split-Path $grafanaExe)
    $grafanaEnv = @{
        GF_SECURITY_ADMIN_USER        = "admin"
        GF_SECURITY_ADMIN_PASSWORD    = "admin"
        GF_AUTH_ANONYMOUS_ENABLED     = "true"
        GF_AUTH_ANONYMOUS_ORG_ROLE    = "Viewer"
        GF_FEATURE_TOGGLES_ENABLE     = "traceqlEditor"
        GF_PATHS_PROVISIONING         = $localProvDir
        GF_PATHS_DATA                 = "$DATA\grafana"
        GF_PATHS_LOGS                 = "$LOGS\grafana"
        GF_PATHS_PLUGINS              = "$DATA\grafana-plugins"
    }
    $procs["grafana"] = Start-Svc "grafana" $grafanaExe "--homepath=$grafanaHome" $null $grafanaEnv
    Start-Sleep -Seconds 3
}

# 7. FastAPI app
Write-Host "`n  [app] Installing Python dependencies ..." -ForegroundColor Cyan
Push-Location "$LAB\01-instrument-fastapi\app"
try {
    & python -m pip install -q -r requirements.txt
    $appEnv = @{
        OTEL_EXPORTER_OTLP_ENDPOINT = "http://localhost:4317"
        OTEL_SERVICE_NAME           = "inference-api"
        DEPLOY_ENV                  = "lab"
        LOG_LEVEL                   = "INFO"
    }
    $uvicornPath = (& python -c "import uvicorn; import os; print(os.path.dirname(uvicorn.__file__))" 2>$null)
    $uvicornExe  = (& python -c "import sys; print(sys.executable)" 2>$null)
    $pi = New-Object System.Diagnostics.ProcessStartInfo
    $pi.FileName  = $uvicornExe
    $pi.Arguments = "-m uvicorn main:app --host 0.0.0.0 --port 8000"
    $pi.UseShellExecute = $false
    $pi.RedirectStandardOutput = $true
    $pi.RedirectStandardError  = $true
    $pi.CreateNoWindow = $true
    $pi.WorkingDirectory = "$LAB\01-instrument-fastapi\app"
    foreach ($kv in $appEnv.GetEnumerator()) { $pi.EnvironmentVariables[$kv.Key] = $kv.Value }
    $proc = [System.Diagnostics.Process]::Start($pi)
    $proc.Id | Out-File "$PIDS\app.pid"
    $procs["app"] = $proc
    Write-Host "  [started] FastAPI app  PID=$($proc.Id)" -ForegroundColor Green
} finally {
    Pop-Location
}

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host "`n=== Stack is up ===" -ForegroundColor Yellow
Write-Host "  App         http://localhost:8000/healthz"
Write-Host "  Prometheus  http://localhost:9090"
Write-Host "  Alertmanager http://localhost:9093"
Write-Host "  Grafana     http://localhost:3000  (admin/admin)"
Write-Host "  Loki        http://localhost:3100/ready"
Write-Host "  Jaeger UI   http://localhost:16686"
Write-Host "  OTel metrics http://localhost:8888/metrics"
Write-Host ""
Write-Host "Run  .\stop-local.ps1  to stop all services." -ForegroundColor DarkGray
Write-Host "Run  python scripts\verify.py  to check rubric." -ForegroundColor DarkGray
