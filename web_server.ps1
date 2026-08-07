#Requires -Version 5.1
<#
.SYNOPSIS
    C Drive Cleaner — 本地 Web 服务器（实时仪表盘）
.DESCRIPTION
    启动本地 HTTP 服务，浏览器访问 http://127.0.0.1:8080 查看 C 盘实时情况。
    提供 API：磁盘状态 / 扫描 / 安全清理 / 深度清理 / 卸载残留 / 备份恢复。
    扫描与清理任务通过后台 PowerShell 进程执行（复用 C_Cleaner.ps1 核心引擎），
    结果写入 web_state\ 目录供前端轮询。

    注意：建议以管理员身份运行本脚本，否则部分路径（如 Program Files、
    System32）无法清理。

.PARAMETER Port
    监听端口，默认 8080
.PARAMETER OpenBrowser
    启动后自动打开浏览器
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File web_server.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File web_server.ps1 -Port 9090 -OpenBrowser
#>
param(
    [int]$Port = 8080,
    [switch]$OpenBrowser
)

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$CoreScript = Join-Path $ScriptRoot "C_Cleaner.ps1"
$WebRoot    = Join-Path $ScriptRoot "web"
$StateDir   = Join-Path $ScriptRoot "web_state"
$LogFile    = Join-Path $ScriptRoot "C_Cleaner.log"
$BackupDir  = Join-Path $ScriptRoot "backups"

if (-not (Test-Path $StateDir)) { New-Item -Path $StateDir -ItemType Directory -Force | Out-Null }
if (-not (Test-Path $WebRoot))  { New-Item -Path $WebRoot  -ItemType Directory -Force | Out-Null }

$script:Tasks = @{}   # taskId -> @{ type; pid; state; start }

$script:IsAdmin = [Security.Principal.WindowsPrincipal]::new(
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# ============================================================
# HTTP helpers
# ============================================================
# 带超时保护的响应写入（防止死连接阻塞主循环）
function Write-ResponseBytes {
    param($Ctx, [byte[]]$Bytes, [string]$ContentType, [int]$Code = 200)
    try {
        $Ctx.Response.StatusCode = $Code
        $Ctx.Response.ContentType = $ContentType
        $Ctx.Response.ContentLength64 = $Bytes.Length
        $Ctx.Response.KeepAlive = $false
        $ar = $Ctx.Response.OutputStream.BeginWrite($Bytes, 0, $Bytes.Length, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne(15000)) {
            $Ctx.Response.Abort()
            return
        }
        $Ctx.Response.OutputStream.EndWrite($ar)
    } catch { }
    try { $Ctx.Response.Close() } catch { }
}

function Send-Json {
    param($Ctx, $Obj, [int]$Code = 200)
    $data = $Obj | ConvertTo-Json -Depth 10 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($data)
    Write-ResponseBytes -Ctx $Ctx -Bytes $bytes -ContentType "application/json; charset=utf-8" -Code $Code
}

function Send-File {
    param($Ctx, [string]$RelPath)
    $full = Join-Path $WebRoot $RelPath
    if (-not (Test-Path $full)) {
        Send-Json -Ctx $Ctx -Obj @{ error = "not found: $RelPath" } -Code 404
        return
    }
    $bytes = [System.IO.File]::ReadAllBytes($full)
    $mime = switch ([System.IO.Path]::GetExtension($full)) {
        ".html" { "text/html; charset=utf-8" }
        ".js"   { "application/javascript; charset=utf-8" }
        ".css"  { "text/css; charset=utf-8" }
        ".svg"  { "image/svg+xml" }
        default { "application/octet-stream" }
    }
    Write-ResponseBytes -Ctx $Ctx -Bytes $bytes -ContentType $mime
}

function Read-BodyJson {
    param($Ctx)
    $sr = New-Object System.IO.StreamReader($Ctx.Request.InputStream)
    $body = $sr.ReadToEnd()
    $sr.Dispose()
    if (-not $body) { return $null }
    try { return ($body | ConvertFrom-Json) } catch { return $null }
}

# ============================================================
# Task management (spawn background cleaner processes)
# ============================================================
function Start-CleanerTask {
    param([string]$Type, [string[]]$CoreArgs)
    # 同类型任务去重：已有运行中任务则返回其 id
    foreach ($k in @($script:Tasks.Keys)) {
        $t = $script:Tasks[$k]
        if ($t.type -eq $Type -and $t.state -eq "running") {
            $alive = Get-Process -Id $t.pid -ErrorAction SilentlyContinue
            if ($alive) { return $k }
            $t.state = "exited"
        }
    }
    $tid = (Get-Date -Format "yyyyMMdd_HHmmss") + "_" + $Type
    # 注意：不使用 Start-Process 的 -RedirectStandardOutput（PS 5.1 有卡死风险），
    # 子进程 stdout 直接丢弃，结果通过 JSON 文件读取，日志写入 C_Cleaner.log
    $argList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$CoreScript`"", "-NoBanner") + $CoreArgs
    try {
        $p = Start-Process powershell.exe -ArgumentList $argList -WindowStyle Hidden -PassThru
        $script:Tasks[$tid] = [PSCustomObject]@{
            type = $Type; pid = $p.Id; state = "running"; start = (Get-Date -Format "HH:mm:ss")
        }
        Write-ServerLog ("[task] {0} started (pid {1}): {2}" -f $Type, $p.Id, ($CoreArgs -join ' '))
        return $tid
    } catch {
        Write-ServerLog ("[task] start failed: {0}" -f $_.Exception.Message)
        return $null
    }
}

function Get-TaskStatus {
    param([string]$Type)
    $resultFile = Join-Path $StateDir "$Type`_result.json"
    $tid = $null; $t = $null
    foreach ($k in @($script:Tasks.Keys)) {
        if ($script:Tasks[$k].type -eq $Type) { $tid = $k; $t = $script:Tasks[$k] }
    }
    # 结果文件已生成且是最近 30 分钟内写入的 → 任务完成（文件是子进程最后写出的）
    if (Test-Path $resultFile) {
        $fAge = (Get-Date) - (Get-Item $resultFile).LastWriteTime
        if ($fAge.TotalMinutes -lt 30) {
            try {
                $data = Get-Content $resultFile -Raw -Encoding UTF8 | ConvertFrom-Json
                return [PSCustomObject]@{ state = "done"; taskId = $tid; result = $data }
            } catch {
                return [PSCustomObject]@{ state = "error"; taskId = $tid; message = "结果文件解析失败" }
            }
        }
    }
    if ($tid -and $t.state -eq "running") {
        $alive = Get-Process -Id $t.pid -ErrorAction SilentlyContinue
        if (-not $alive) { $t.state = "exited" }
        if ($t.state -eq "running") {
            return [PSCustomObject]@{
                state = "running"; taskId = $tid; started = $t.start
                resultFile = $resultFile
            }
        }
        # 进程已退出但无结果文件 → 任务失败
        $errHint = ""
        return [PSCustomObject]@{ state = "error"; taskId = $tid; message = "任务进程已退出但未生成结果（可能执行失败，请查看日志）$errHint" }
    }
    return [PSCustomObject]@{ state = "idle"; taskId = $null }
}

# ============================================================
# API implementations
# ============================================================
function Get-DiskInfo {
    @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
        Where-Object { $null -ne $_.Used } |
        ForEach-Object {
            $total = $_.Used + $_.Free
            [PSCustomObject]@{
                letter = $_.Name
                totalGB = [math]::Round($total / 1GB, 2)
                usedGB = [math]::Round($_.Used / 1GB, 2)
                freeGB = [math]::Round($_.Free / 1GB, 2)
                usedPercent = if ($total -gt 0) { [math]::Round($_.Used / $total * 100, 1) } else { 0 }
            }
        })
}

function Get-BackupList {
    if (-not (Test-Path $BackupDir)) { return @() }
    @(Get-ChildItem $BackupDir -Filter "*.zip" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        ForEach-Object {
            $info = ""
            $mp = "$($_.FullName).meta"
            if (Test-Path $mp) {
                try {
                    $m = Get-Content $mp -Raw -Encoding UTF8 | ConvertFrom-Json
                    $info = [PSCustomObject]@{
                        original = $m.OriginalPath
                        sizeMB = $m.SizeMB
                        date = $m.BackupDate
                    }
                } catch { }
            }
            [PSCustomObject]@{
                name = $_.Name
                sizeKB = [math]::Round($_.Length / 1KB, 1)
                created = $_.LastWriteTime.ToString("yyyy-MM-dd HH:mm")
                info = $info
            }
        })
}

# ============================================================
# Router
# ============================================================
function Process-Request {
    param($Ctx)
    $method = $Ctx.Request.HttpMethod
    $path = $Ctx.Request.Url.AbsolutePath
    Write-ServerLog ("  {0} {1}" -f $method, $path)

    switch -Regex ($path) {
        "^/$" {
            Send-File -Ctx $Ctx -RelPath "index.html"
        }
        "^/api/status$" {
            Send-Json -Ctx $Ctx -Obj @{
                ok = $true
                app = "C Drive Cleaner"
                version = "2.1.0"
                isAdmin = $script:IsAdmin
                stateDir = $StateDir
                time = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            }
        }
        "^/api/disk$" {
            Send-Json -Ctx $Ctx -Obj @{
                timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                drives = Get-DiskInfo
            }
        }
        "^/api/scan$" {
            if ($method -ne "POST") { Send-Json -Ctx $Ctx -Obj @{ error = "POST required" } -Code 405; return }
            $tid = Start-CleanerTask -Type "scan" -CoreArgs @("-Mode", "Scan", "-ExportJson", (Join-Path $StateDir "scan_result.json"))
            if ($tid) {
                Send-Json -Ctx $Ctx -Obj @{ ok = $true; taskId = $tid; message = "扫描已启动" }
            } else {
                Send-Json -Ctx $Ctx -Obj @{ ok = $false; error = "任务启动失败（可能是权限或路径问题）" } -Code 500
            }
        }
        "^/api/residue$" {
            if ($method -ne "POST") { Send-Json -Ctx $Ctx -Obj @{ error = "POST required" } -Code 405; return }
            $tid = Start-CleanerTask -Type "residue" -CoreArgs @("-Mode", "ResidueScan", "-ExportJson", (Join-Path $StateDir "residue_result.json"))
            if ($tid) {
                Send-Json -Ctx $Ctx -Obj @{ ok = $true; taskId = $tid; message = "卸载残留扫描已启动" }
            } else {
                Send-Json -Ctx $Ctx -Obj @{ ok = $false; error = "任务启动失败" } -Code 500
            }
        }
        "^/api/task$" {
            $type = $Ctx.Request.QueryString["type"]
            if (-not $type -or $type -notin @("scan", "residue", "clean", "restore")) {
                Send-Json -Ctx $Ctx -Obj @{ error = "type=scan|residue|clean|restore required" } -Code 400
                return
            }
            Send-Json -Ctx $Ctx -Obj (Get-TaskStatus -Type $type)
        }
        "^/api/clean$" {
            if ($method -ne "POST") { Send-Json -Ctx $Ctx -Obj @{ error = "POST required" } -Code 405; return }
            $req = Read-BodyJson -Ctx $Ctx
            if (-not $req) { Send-Json -Ctx $Ctx -Obj @{ error = "无效的 JSON 请求体" } -Code 400; return }

            if ($req.mode -eq "ResidueClean") {
                if (-not $req.residues -or @($req.residues).Count -eq 0) {
                    Send-Json -Ctx $Ctx -Obj @{ error = "residues 列表为空" } -Code 400; return
                }
                $reqFile = Join-Path $StateDir "clean_request.json"
                $req | ConvertTo-Json -Depth 10 | Set-Content $reqFile -Encoding UTF8
                $tid = Start-CleanerTask -Type "clean" -CoreArgs @("-Mode", "ResidueClean", "-CleanFromJson", $reqFile, "-ExportJson", (Join-Path $StateDir "clean_result.json"))
            } elseif ($req.mode -in @("SafeClean", "DeepClean")) {
                if (-not $req.paths -or @($req.paths).Count -eq 0) {
                    Send-Json -Ctx $Ctx -Obj @{ error = "paths 列表为空" } -Code 400; return
                }
                $reqFile = Join-Path $StateDir "clean_request.json"
                $req | ConvertTo-Json -Depth 10 | Set-Content $reqFile -Encoding UTF8
                $tid = Start-CleanerTask -Type "clean" -CoreArgs @("-Mode", $req.mode, "-CleanFromJson", $reqFile, "-ExportJson", (Join-Path $StateDir "clean_result.json"))
            } else {
                Send-Json -Ctx $Ctx -Obj @{ error = "mode 必须是 SafeClean / DeepClean / ResidueClean" } -Code 400
                return
            }
            if ($tid) {
                Send-Json -Ctx $Ctx -Obj @{ ok = $true; taskId = $tid; message = "清理任务已启动" }
            } else {
                Send-Json -Ctx $Ctx -Obj @{ ok = $false; error = "任务启动失败" } -Code 500
            }
        }
        "^/api/backups$" {
            Send-Json -Ctx $Ctx -Obj @{ backups = Get-BackupList }
        }
        "^/api/restore$" {
            if ($method -ne "POST") { Send-Json -Ctx $Ctx -Obj @{ error = "POST required" } -Code 405; return }
            $req = Read-BodyJson -Ctx $Ctx
            if (-not $req -or -not $req.name) { Send-Json -Ctx $Ctx -Obj @{ error = "name 必填" } -Code 400; return }
            $tid = Start-CleanerTask -Type "restore" -CoreArgs @("-Mode", "Restore", "-RestoreBackup", $req.name, "-ExportJson", (Join-Path $StateDir "restore_result.json"))
            if ($tid) {
                Send-Json -Ctx $Ctx -Obj @{ ok = $true; taskId = $tid; message = "恢复任务已启动" }
            } else {
                Send-Json -Ctx $Ctx -Obj @{ ok = $false; error = "任务启动失败" } -Code 500
            }
        }
        "^/api/log$" {
            $lines = @()
            if ([System.IO.File]::Exists($LogFile)) {
                # 用 .NET 原语读取，避免 Get-Content 管道在特定文件状态下挂起
                $text = [System.IO.File]::ReadAllText($LogFile, [System.Text.Encoding]::UTF8)
                $all = @($text -split "`r?`n")
                if ($all.Length -gt 300) { $all = @($all[($all.Length - 300)..($all.Length - 1)]) }
                $lines = $all
            }
            Send-Json -Ctx $Ctx -Obj @{ lines = $lines }
        }
        default {
            Send-Json -Ctx $Ctx -Obj @{ error = "not found: $path" } -Code 404
        }
    }
}

# ============================================================
# Server main loop
# ============================================================
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
try {
    $listener.Start()
} catch {
    Write-Host ("无法监听端口 {0}: {1}" -f $Port, $_.Exception.Message) -ForegroundColor Red
    Write-Host "端口可能被占用，可改用 -Port 参数指定其他端口。" -ForegroundColor Yellow
    exit 1
}

$HeartbeatFile = Join-Path $StateDir "server_heartbeat.txt"
$ServerLog = Join-Path $StateDir "server.log"

# 所有日志直接写文件——避免 stdout 重定向管道的缓冲阻塞（后台运行时管道写满会导致假死）
function Write-ServerLog {
    param([string]$Message)
    try {
        ("[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $Message) |
            Add-Content $ServerLog -Encoding UTF8
    } catch { }
}
function Write-Heartbeat {
    param([string]$Status = "ok")
    try {
        ("{0} | {1} | {2} MB" -f (Get-Date -Format "HH:mm:ss"), $Status,
            [math]::Round((Get-Process -Id $PID).WorkingSet64 / 1MB)) |
            Set-Content $HeartbeatFile -Encoding UTF8
    } catch { }
}
Write-Heartbeat -Status "started"
Write-ServerLog "server started, port $Port"

Write-Host ""
Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host "  C Drive Cleaner Web Server v2.1" -ForegroundColor Cyan
Write-Host ("  打开浏览器: http://127.0.0.1:{0}" -f $Port) -ForegroundColor White
Write-Host ("  当前权限:   {0}" -f $(if ($script:IsAdmin) { "管理员（推荐）" } else { "普通用户（清理受限，建议管理员运行）" })) -ForegroundColor $(if ($script:IsAdmin) { "Green" } else { "Yellow" })
Write-Host "  按 Ctrl+C 停止服务" -ForegroundColor DarkGray
Write-Host "==============================================================" -ForegroundColor Cyan
Write-Host ""

if ($OpenBrowser) {
    Start-Process "http://127.0.0.1:$Port/"
}

try {
    while ($listener.IsListening) {
        # 同步等待请求（空闲等待本身无害）。注意：不要用 BeginGetContext+超时，
        # 超时后旧等待注册无法取消，会向 HTTP.sys 泄漏永久等待导致假死。
        $ctx = $listener.GetContext()
        $reqStart = Get-Date
        $reqMethod = $ctx.Request.HttpMethod
        $reqPath = $ctx.Request.Url.AbsolutePath
        try {
            Process-Request -Ctx $ctx
            $elapsed = [math]::Round(((Get-Date) - $reqStart).TotalSeconds, 1)
            if ($elapsed -gt 5) {
                Write-ServerLog ("  [slow] {0} {1} took {2}s" -f $reqMethod, $reqPath, $elapsed)
            }
            Write-Heartbeat
        } catch {
            Write-ServerLog ("  [error] {0} {1}: {2}" -f $reqMethod, $reqPath, $_.Exception.Message)
            Write-Heartbeat -Status "error"
            try { $ctx.Response.Abort() } catch { }
        }
    }
} finally {
    $listener.Stop()
    Write-Heartbeat -Status "stopped"
    Write-Host "Web server stopped." -ForegroundColor Yellow
}
