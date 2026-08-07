#Requires -Version 5.1
<#
.SYNOPSIS
    C Drive Safe Cleaner — Universal Scan + 80-Software KB + 3-Level Safety + Junction Migration
.DESCRIPTION
    Core design: never interrupt any running software, never lose any user data.
    Supports -WhatIf (preview), safe clean, deep clean, directory migration, one-key restore.
.PARAMETER Mode
    Scan, SafeClean, DeepClean, Migrate, Restore
.PARAMETER TargetDrive
    Migration target drive letter (Migrate mode only)
.PARAMETER ExportReport
    Export HTML report path
.PARAMETER ConfigPath
    Custom config.json path
.PARAMETER SkipProcessCheck
    Skip running process detection (use with caution)
.EXAMPLE
    .\C_Cleaner.ps1 -WhatIf -Mode Scan
.EXAMPLE
    .\C_Cleaner.ps1 -Mode SafeClean
.EXAMPLE
    .\C_Cleaner.ps1 -Mode Migrate -TargetDrive D -WhatIf
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet("Scan", "SafeClean", "DeepClean", "Migrate", "Restore", "ResidueScan", "ResidueClean")]
    [string]$Mode = "Scan",

    [string]$TargetDrive = "D",

    [string]$ExportReport = "",

    [string]$ConfigPath = "",

    [string]$ExportJson = "",

    [string]$CleanFromJson = "",

    [string]$RestoreBackup = "",

    [switch]$SkipProcessCheck,

    [switch]$NoBanner
)

# ============================================================
# Global Config & Init
# ============================================================
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogFile = Join-Path $ScriptRoot "C_Cleaner.log"
$BackupDir = Join-Path $ScriptRoot "backups"
$KBFile = Join-Path $ScriptRoot "software_knowledge.json"
$ConfigFile = if ($ConfigPath) { $ConfigPath } else { Join-Path $ScriptRoot "config.json" }
$UnknownRegistry = Join-Path $ScriptRoot "unknown_software_registry.json"

$Stats = @{
    TotalScanned = 0; TotalSize = 0; GreenItems = 0
    YellowItems = 0; RedItems = 0; Cleaned = 0; Migrated = 0; Skipped = 0
}
$KnowledgeBase = $null
$RunningProcesses = @()
$SystemDrive = $env:SystemDrive

$SystemProtectedPaths = @(
    "$env:SystemRoot\System32",
    "$env:SystemRoot\SysWOW64",
    "$env:SystemRoot\WinSxS",
    "$env:SystemRoot\System",
    "$env:SystemRoot\Boot",
    "$env:SystemRoot\INF",
    "$env:SystemRoot\DriverStore",
    "$env:SystemRoot\SystemResources",
    "$env:SystemRoot\Microsoft.NET"
)

# ============================================================
# Config Loader
# ============================================================
function Get-CleanerConfig {
    $default = @{
        target_drive             = "D"
        min_file_age_days        = 7
        min_size_mb              = 50
        max_scan_depth           = 2
        excluded_paths           = @()
        auto_confirm_green       = $true
        preserve_junction_backup = $true
        robocopy_retry           = 3
        robocopy_wait            = 2
        sample_verification_count = 20
        scan_downloads           = $true
        scan_documents           = $false
        scan_system_temp         = $true
        scan_recycle_bin         = $false
        excluded_users           = @("Public", "Default", "Default User")
        category_enabled         = @{}
        log_retention_days       = 30
        backup_retention_days    = 90
    }
    if (Test-Path $ConfigFile) {
        try {
            $user = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($k in $default.Keys) {
                if ($null -eq $user.$k) {
                    $user | Add-Member -NotePropertyName $k -NotePropertyValue $default[$k] -Force
                }
            }
            return $user
        } catch { }
    }
    return [PSCustomObject]$default
}

$Config = Get-CleanerConfig

# ============================================================
# Logger
# ============================================================
function Write-Log {
    param([string]$Level = "INFO", [string]$Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$ts] [$Level] $Message"
    # 用 .NET 追加而非 Add-Content：-WhatIf 是通用参数会传播，Add-Content 会被静默
    # 抑制导致预览模式下日志丢失（-WhatIf 时应照常记录日志）
    try { [System.IO.File]::AppendAllText($LogFile, $entry + "`r`n", [System.Text.UTF8Encoding]::new($false)) } catch { }
    $color = switch ($Level) {
        "ERROR"   { "Red" }
        "WARN"    { "Yellow" }
        "SUCCESS" { "Green" }
        default   { "Gray" }
    }
    Write-Host $entry -ForegroundColor $color
}

# ============================================================
# Process Detection
# ============================================================
function Get-RunningProcesses {
    if ($SkipProcessCheck) {
        Write-Log "INFO" "Process detection skipped"
        return @()
    }
    Write-Log "INFO" "Detecting running processes..."
    $procs = @()
    $seen = @{}
    Get-Process | Where-Object { $_.Id -ne 0 -and $_.Id -ne 4 } | ForEach-Object {
        try {
            $p = $_.MainModule.FileName
            if ($p -and -not $seen.ContainsKey($p)) {
                $seen[$p] = $true
                $procs += [PSCustomObject]@{ Id = $_.Id; Name = $_.ProcessName; Path = $p }
            }
        } catch { }
    }
    Write-Log "SUCCESS" ("Detected {0} running processes" -f $procs.Count)
    return $procs
}

function Test-IsLockedByProcess {
    param([string]$Path, [array]$Procs)
    # 语义：该目录内是否正有进程的 exe 在运行（如 WeChat 目录里跑着 WeChat.exe）。
    # 修复前逻辑是"目标父目录以进程exe所在目录开头"，会把 C:\Windows 下所有目录
    # 判为使用中（explorer.exe 住在 C:\Windows），还有 MyApp/MyApp2 前缀碰撞误判，
    # 导致 Windows 更新缓存等残留永远无法清理。
    $d = $Path.TrimEnd('\').ToLower() + '\'
    foreach ($p in $Procs) {
        if ($p.Path -and $p.Path.ToLower().StartsWith($d)) { return $p }
    }
    return $null
}

# ============================================================
# Knowledge Base Engine
# ============================================================
function Import-KnowledgeBase {
    if (Test-Path $KBFile) {
        try {
            $script:KnowledgeBase = Get-Content $KBFile -Raw -Encoding UTF8 | ConvertFrom-Json
            Write-Log "SUCCESS" ("Knowledge base loaded: {0} software entries" -f $script:KnowledgeBase.software.Count)
        } catch {
            Write-Log "ERROR" ("Knowledge base corrupt: {0}" -f $_.Exception.Message)
        }
    } else {
        Write-Log "WARN" "Knowledge base file not found"
    }
}

function Find-KnownSoftware {
    param([string]$Path)
    if (-not $script:KnowledgeBase) { return $null }
    $np = $Path.ToLower().Replace('/', '\')
    foreach ($sw in $script:KnowledgeBase.software) {
        foreach ($pat in $sw.path_patterns) {
            $np2 = $pat.ToLower().Replace('/', '\')
            $rx = [regex]::Escape($np2).Replace('\*', '.*').Replace('\?', '.')
            if ($np -match $rx) { return $sw }
        }
    }
    return $null
}

function Register-UnknownApp {
    param([string]$Path, [string]$Category)
    $reg = @()
    if (Test-Path $UnknownRegistry) {
        try { $reg = Get-Content $UnknownRegistry -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    }
    $dn = Split-Path $Path -Leaf
    $pa = Split-Path $Path -Parent
    $entry = [PSCustomObject]@{
        name = $dn; category = $Category
        path_pattern = "$pa\$dn"; detected_date = (Get-Date -Format "yyyy-MM-dd")
        hit_count = 1; suggested_level = "Yellow"
    }
    $ex = $reg | Where-Object { $_.path_pattern -eq $entry.path_pattern }
    if (-not $ex) {
        $reg += $entry
        try { $reg | ConvertTo-Json -Depth 4 | Set-Content $UnknownRegistry -Encoding UTF8 } catch { }
        Write-Log "INFO" ("Registered unknown app: {0}" -f $dn)
    } else {
        $ex.hit_count++
        try { $reg | ConvertTo-Json -Depth 4 | Set-Content $UnknownRegistry -Encoding UTF8 } catch { }
    }
}

# ============================================================
# Helper: check if path is excluded
# ============================================================
function Test-IsExcluded {
    param([string]$Path)
    $np = $Path.ToLower().Replace('/', '\')
    foreach ($ex in $Config.excluded_paths) {
        $exNorm = $ex.ToLower().Replace('/', '\').TrimEnd('\')
        if ($np -eq $exNorm -or $np.StartsWith($exNorm + '\')) { return $true }
    }
    return $false
}

function Test-IsCategoryEnabled {
    param($Software)
    if (-not $Software) { return $true }
    $cat = $Software.category
    if (-not $cat) { return $true }
    if ($Config.category_enabled -and $Config.category_enabled.PSObject.Properties) {
        $val = $Config.category_enabled.$cat
        if ($null -ne $val) { return $val }
    }
    return $true
}

# ============================================================
# 3-Level Safety Classification
# ============================================================
function Get-SafetyLevel {
    param([string]$Path)
    $np = $Path.ToLower().Replace('/', '\')

    # RED: System protected paths（带分隔符边界，避免 System32Foo 之类前缀误判）
    foreach ($prot in $SystemProtectedPaths) {
        $pp = $prot.ToLower()
        if ($np -eq $pp -or $np.StartsWith($pp + '\')) {
            return @{ Level = "Red"; Reason = "System protected: $prot" }
        }
    }

    # Junction/符号链接：目标可能在别的盘或含真实数据，不自动清理（降到需确认）
    try {
        if (([System.IO.File]::GetAttributes($Path) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            return @{ Level = "Yellow"; Reason = "Junction/symlink, needs manual review" }
        }
    } catch { }

    # RED: Running software directories
    $lp = Test-IsLockedByProcess -Path $Path -Procs $RunningProcesses
    if ($lp) {
        return @{ Level = "Red"; Reason = "Process running: $($lp.Name)" }
    }

    # Known software match
    $sw = Find-KnownSoftware -Path $Path
    if ($sw) {
        if (-not (Test-IsCategoryEnabled -Software $sw)) {
            return @{ Level = "Yellow"; Reason = "Category disabled: $($sw.name)"; Software = $sw }
        }
        $lvl = $sw.safety_level.ToLower()
        if ($lvl -eq "green" -or $lvl -eq "safe") {
            return @{ Level = "Green"; Reason = "Known cache: $($sw.name)"; Software = $sw }
        }
        if ($lvl -eq "yellow" -or $lvl -eq "confirm") {
            return @{ Level = "Yellow"; Reason = "User data: $($sw.name)"; Software = $sw }
        }
        return @{ Level = "Red"; Reason = "System critical: $($sw.name)"; Software = $sw }
    }

    # Auto-classify by path pattern
    # \\crash 带边界：避免 "crash reports" 之类文档目录被误判为缓存自动清理
    if ($np -match '\\cache\\|\\temp\\|\\tmp\\|\\logs?\\|\\thumbnails?\\|\\crash(\\|[\s\-_.]|$)|\.cache\\') {
        Register-UnknownApp -Path $Path -Category "auto-cache"
        return @{ Level = "Green"; Reason = "Auto-detected cache directory" }
    }
    if ($np -match '\\appdata\\') {
        Register-UnknownApp -Path $Path -Category "auto-appdata"
        return @{ Level = "Yellow"; Reason = "AppData directory, needs review" }
    }
    Register-UnknownApp -Path $Path -Category "unclassified"
    return @{ Level = "Yellow"; Reason = "Unknown type, default to review" }
}

# ============================================================
# Universal Scan Engine
# ============================================================
function Invoke-Scan {
    Write-Log "INFO" "===== Universal Scan Engine ====="
    Write-Log "INFO" ("System drive: {0}" -f $SystemDrive)
    Write-Log "INFO" ("Min size threshold: {0} MB" -f $Config.min_size_mb)
    Write-Log "INFO" ("Min file age: {0} days" -f $Config.min_file_age_days)
    Write-Log "INFO" ("Max scan depth: {0}" -f $Config.max_scan_depth)

    $results = [System.Collections.ArrayList]::new()
    $userDirs = Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue

    if (-not $userDirs) {
        Write-Log "WARN" "No user directories found under C:\\Users"
        return @()
    }

    $cutoffDate = (Get-Date).AddDays(-$Config.min_file_age_days)
    $total = $userDirs.Count
    Write-Log "INFO" ("Found {0} user directories" -f $total)

    $ui = 0
    foreach ($ud in $userDirs) {
        $ui++
        $un = $ud.Name

        # Skip excluded users
        if ($un -in $Config.excluded_users -or $un.EndsWith('$')) { continue }

        Write-Progress -Activity "Scanning user directories" -Status $un -PercentComplete (($ui / $total) * 100)
        Write-Log "INFO" ("[{0}/{1}] Scanning user: {2}" -f $ui, $total, $un)

        $roots = @(
            "$($ud.FullName)\AppData\Local",
            "$($ud.FullName)\AppData\Roaming",
            "$($ud.FullName)\AppData\LocalLow"
        )

        # Optionally add Downloads
        if ($Config.scan_downloads) {
            $dlPath = "$($ud.FullName)\Downloads"
            if (Test-Path $dlPath) { $roots += $dlPath }
        }

        foreach ($r in $roots) {
            if (-not (Test-Path $r)) { continue }
            if (Test-IsExcluded -Path $r) { continue }

            try {
                $subs = Get-ChildItem $r -Directory -ErrorAction SilentlyContinue -Depth $Config.max_scan_depth
                foreach ($sd in $subs) {
                    try {
                        if (Test-IsExcluded -Path $sd.FullName) { continue }
                        if ($sd.LastWriteTime -gt $cutoffDate -and $Config.min_file_age_days -gt 0) { continue }

                        $files = Get-ChildItem $sd.FullName -Recurse -File -ErrorAction SilentlyContinue
                        $sz = ($files | Measure-Object -Property Length -Sum).Sum
                        if (-not $sz -or $sz -lt ($Config.min_size_mb * 1MB)) { continue }
                        $fc = $files.Count
                        $szMB = [math]::Round($sz / 1MB, 2)
                        $cls = Get-SafetyLevel -Path $sd.FullName

                        [void]$results.Add([PSCustomObject]@{
                            FullPath     = $sd.FullName
                            Name         = $sd.Name
                            User         = $un
                            SizeBytes    = $sz
                            SizeMB       = $szMB
                            FileCount    = $fc
                            SafetyLevel  = $cls.Level
                            SafetyReason = $cls.Reason
                            Software     = $cls.Software
                            LastModified = $sd.LastWriteTime
                            ParentPath   = $r
                        })
                    } catch {
                        Write-Log "WARN" ("Skipping {0}: {1}" -f $sd.FullName, $_.Exception.Message)
                    }
                }
            } catch {
                Write-Log "WARN" ("Cannot access {0}: {1}" -f $r, $_.Exception.Message)
            }
        }
    }

    Write-Progress -Activity "Scanning user directories" -Completed

    # ProgramData scan (non-Microsoft, non-excluded)
    Write-Log "INFO" "Scanning ProgramData..."
    $skipPD = @("Microsoft", "Package Cache", "USOPrivate", "USOShared", "Microsoft OneDrive")
    try {
        Get-ChildItem "C:\ProgramData" -Directory -ErrorAction SilentlyContinue -Depth 0 |
        Where-Object { $_.Name -notin $skipPD } | ForEach-Object {
            try {
                if (Test-IsExcluded -Path $_.FullName) { return }
                if ($_.LastWriteTime -gt $cutoffDate -and $Config.min_file_age_days -gt 0) { return }

                $files = Get-ChildItem $_.FullName -Recurse -File -ErrorAction SilentlyContinue
                $sz = ($files | Measure-Object -Property Length -Sum).Sum
                if (-not $sz -or $sz -lt ($Config.min_size_mb * 1MB)) { return }
                $fc = $files.Count
                $szMB = [math]::Round($sz / 1MB, 2)
                $cls = Get-SafetyLevel -Path $_.FullName
                [void]$results.Add([PSCustomObject]@{
                    FullPath     = $_.FullName
                    Name         = $_.Name
                    User         = "AllUsers"
                    SizeBytes    = $sz
                    SizeMB       = $szMB
                    FileCount    = $fc
                    SafetyLevel  = $cls.Level
                    SafetyReason = $cls.Reason
                    Software     = $cls.Software
                    LastModified = $_.LastWriteTime
                    ParentPath   = "C:\ProgramData"
                })
            } catch {
                Write-Log "WARN" ("Skipping ProgramData item: {0}" -f $_.Exception.Message)
            }
        }
    } catch { }

    # System temp scan (if enabled)
    if ($Config.scan_system_temp) {
        Write-Log "INFO" "Scanning system temp directories..."
        $tempPaths = @("$env:SystemRoot\Temp", $env:TEMP, $env:TMP) | Select-Object -Unique
        foreach ($tp in $tempPaths) {
            if (-not $tp -or -not (Test-Path $tp)) { continue }
            try {
                $files = Get-ChildItem $tp -Recurse -File -ErrorAction SilentlyContinue -Depth 2
                $sz = ($files | Measure-Object -Property Length -Sum).Sum
                if (-not $sz -or $sz -lt ($Config.min_size_mb * 1MB)) { continue }
                $fc = $files.Count
                $szMB = [math]::Round($sz / 1MB, 2)
                [void]$results.Add([PSCustomObject]@{
                    FullPath     = $tp
                    Name         = (Split-Path $tp -Leaf)
                    User         = "System"
                    SizeBytes    = $sz
                    SizeMB       = $szMB
                    FileCount    = $fc
                    SafetyLevel  = "Green"
                    SafetyReason = "System temp directory"
                    Software     = $null
                    LastModified = (Get-Date)
                    ParentPath   = (Split-Path $tp -Parent)
                })
            } catch {
                Write-Log "WARN" ("Skipping temp path {0}: {1}" -f $tp, $_.Exception.Message)
            }
        }
    }

    $sorted = $results | Sort-Object -Property SizeBytes -Descending

    $Stats.TotalScanned = $sorted.Count
    $Stats.TotalSize = ($sorted | Measure-Object -Property SizeBytes -Sum).Sum
    $Stats.GreenItems = ($sorted | Where-Object { $_.SafetyLevel -eq "Green" }).Count
    $Stats.YellowItems = ($sorted | Where-Object { $_.SafetyLevel -eq "Yellow" }).Count
    $Stats.RedItems = ($sorted | Where-Object { $_.SafetyLevel -eq "Red" }).Count

    $totalGB = [math]::Round($Stats.TotalSize / 1GB, 2)
    Write-Log "SUCCESS" ("Scan complete: {0} items, {1} GB" -f $sorted.Count, $totalGB)
    return $sorted
}

# ============================================================
# Backup & Restore
# ============================================================
function Get-FilesNoReparse {
    param([string]$Path)
    # PS 5.1 的 Get-ChildItem -Recurse 会穿越 junction（实测返回链接目标内容），
    # 备份会把别的盘的内容打进 zip 且条目名错位、体积暴涨，junction 成环还会卡死。
    # 这里手动递归并跳过 reparse point，返回 @{FullName; Length} 对象列表。
    $out = New-Object System.Collections.ArrayList
    try {
        foreach ($f in [System.IO.Directory]::EnumerateFiles($Path)) {
            $fi = [System.IO.FileInfo]::new($f)
            [void]$out.Add([PSCustomObject]@{ FullName = $fi.FullName; Length = $fi.Length })
        }
        foreach ($d in [System.IO.Directory]::EnumerateDirectories($Path)) {
            if (([System.IO.File]::GetAttributes($d) -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) {
                foreach ($x in Get-FilesNoReparse -Path $d) { [void]$out.Add($x) }
            }
        }
    } catch { }
    return @($out)
}

function Backup-Item {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    if (-not (Test-Path $BackupDir)) {
        New-Item -Path $BackupDir -ItemType Directory -Force | Out-Null
    }
    $ts = Get-Date -Format "yyyyMMdd_HHmmss"
    $sn = $Path.Replace(':', '').Replace('\', '_').Replace(' ', '_')
    if ($sn.Length -gt 80) { $sn = $sn.Substring(0, 80) }
    $bn = "{0}_{1}.zip" -f $sn, $ts
    $bp = Join-Path $BackupDir $bn
    try {
        $files = Get-FilesNoReparse -Path $Path
        $mb = ($files | Measure-Object -Property Length -Sum).Sum / 1MB
        $meta = @{
            OriginalPath = $Path
            BackupDate   = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
            SizeMB       = [math]::Round($mb, 2)
        }
        $meta | ConvertTo-Json | Set-Content "$bp.meta" -Encoding UTF8

        # 注意：不要用 Compress-Archive —— PS 5.1 下源目录内只要有一个文件被其他进程
        # 锁定（典型如 %TEMP%），整个压缩就失败（“流不可读”）。这里手动打包，
        # 被锁定的文件逐个跳过，保证备份总能完成。
        # PS 5.1 默认未加载 System.IO.Compression，必须先 Add-Type，否则类型找不到。
        Add-Type -AssemblyName System.IO.Compression
        $rootName = Split-Path $Path -Leaf
        $skipped = 0
        Write-Host ("  Backing up {0} MB..." -f [math]::Round($mb, 2)) -ForegroundColor Gray
        $fs = [System.IO.File]::Open($bp, [System.IO.FileMode]::Create, [System.IO.FileAccess]::ReadWrite)
        $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($f in $files) {
                # 先探测可读性：被进程独占锁定的文件直接跳过，不影响备份整体
                try {
                    $probe = [System.IO.File]::OpenRead($f.FullName)
                    $probe.Dispose()
                } catch {
                    $skipped++
                    continue
                }
                $rel = $f.FullName.Substring($Path.Length).TrimStart('\')
                $entry = $zip.CreateEntry($rootName + '\' + $rel, [System.IO.Compression.CompressionLevel]::Optimal)
                try {
                    $in = [System.IO.File]::OpenRead($f.FullName)
                    try {
                        $out = $entry.Open()
                        try { $in.CopyTo($out) } finally { $out.Dispose() }
                    } finally { $in.Dispose() }
                } catch {
                    $skipped++
                }
            }
        } finally {
            $zip.Dispose()
            $fs.Dispose()
        }
        if ($skipped -gt 0) {
            Write-Log "WARN" ("Backed up: {0} -> {1} ({2} locked files skipped)" -f $Path, $bp, $skipped)
        } else {
            Write-Log "INFO" ("Backed up: {0} -> {1}" -f $Path, $bp)
        }
        return $bp
    } catch {
        try { Remove-Item $bp -Force -ErrorAction SilentlyContinue } catch { }
        try { Remove-Item "$bp.meta" -Force -ErrorAction SilentlyContinue } catch { }
        Write-Log "ERROR" ("Backup failed: {0} - {1}" -f $Path, $_.Exception.Message)
        return $null
    }
}

function Remove-DirTolerant {
    param([string]$Path)
    # 用 .NET API 逐项删除（子项优先），被进程锁定的项跳过并计数。
    # 为什么不用 Remove-Item / Get-ChildItem：
    #   1. PS 5.1 的 Remove-Item -Recurse 遇到 "pending delete" 状态的子目录会无限挂起
    #      （2026-08-06 实测：%TEMP% 清理时子进程 CPU 冻结在收尾步骤）；
    #   2. PS 5.1 的 Get-ChildItem -Recurse 会穿越 junction，可能误删链接目标目录；
    #   3. 枚举本身在锁定目录上也可能挂起。
    # 这里手动递归 + 跳过 reparse point，.NET Delete 对锁定项快速失败、不等待。
    # 返回 @{ deleted; kept } —— 调用方据此诚实统计（全部被锁/无权限时不得报"已清理"）。
    $total = 0
    $kept = 0
    # 入口检查：$Path 本身若是 junction/符号链接，绝不枚举其目标内容——目标可能在别的
    # 盘、含真实数据（如本工具 Migrate 生成的联接）。reparse point 一律跳过不清理。
    try {
        if (([System.IO.File]::GetAttributes($Path) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            return [PSCustomObject]@{ deleted = 0; kept = 1 }
        }
    } catch { }
    try {
        foreach ($f in [System.IO.Directory]::EnumerateFiles($Path)) {
            $total++
            try { [System.IO.File]::Delete($f) } catch { $kept++ }
        }
        foreach ($d in [System.IO.Directory]::EnumerateDirectories($Path)) {
            $total++
            if (([System.IO.File]::GetAttributes($d) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                # junction/符号链接：只删链接本身，绝不进入目标目录
                try { [System.IO.Directory]::Delete($d, $false) } catch { $kept++ }
            } else {
                $r = Remove-DirTolerant -Path $d
                $total += $r.deleted + $r.kept
                $kept += $r.kept
            }
        }
    } catch { $kept++ }
    # 内容清空后尝试删除本目录（被进程占用时自动跳过，保留空目录无副作用）
    try { [System.IO.Directory]::Delete($Path, $false) } catch { }
    return [PSCustomObject]@{ deleted = ($total - $kept); kept = $kept }
}

function Restore-Backup {
    param([string]$BackupPath)
    if (-not (Test-Path $BackupPath)) {
        Write-Log "ERROR" "Backup not found: $BackupPath"
        return $false
    }
    try {
        $mp = "$BackupPath.meta"
        if (-not (Test-Path $mp)) { Write-Log "ERROR" "Metadata missing"; return $false }
        $meta = Get-Content $mp -Raw -Encoding UTF8 | ConvertFrom-Json
        $orig = $meta.OriginalPath
        $parent = Split-Path $orig -Parent
        if (-not (Test-Path $parent)) {
            New-Item -Path $parent -ItemType Directory -Force | Out-Null
        }
        # 解压到父目录：Compress-Archive 保留顶层目录名，解压后路径与 $orig 一致
        Expand-Archive -Path $BackupPath -DestinationPath $parent -Force
        Write-Log "SUCCESS" ("Restored: {0} -> {1}" -f $BackupPath, $orig)
        return $true
    } catch {
        Write-Log "ERROR" ("Restore failed: {0}" -f $_.Exception.Message)
        return $false
    }
}

function Invoke-RestoreAll {
    Write-Log "INFO" "===== Restore Mode ====="
    if (-not (Test-Path $BackupDir)) {
        Write-Host "No backup directory found." -ForegroundColor Yellow
        return
    }
    $baks = Get-ChildItem $BackupDir -Filter "*.zip" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending

    if ($baks.Count -eq 0) {
        Write-Host "No backups found." -ForegroundColor Yellow
        return
    }

    Write-Host ("Found {0} backups:" -f $baks.Count) -ForegroundColor Cyan
    for ($i = 0; $i -lt $baks.Count; $i++) {
        $b = $baks[$i]
        $info = ""
        $mp = "$($b.FullName).meta"
        if (Test-Path $mp) {
            try {
                $m = Get-Content $mp -Raw -Encoding UTF8 | ConvertFrom-Json
                $szMB = [math]::Round($m.SizeMB, 2)
                $info = " | Orig: {0} | Size: {1} MB" -f $m.OriginalPath, $szMB
            } catch { }
        }
        Write-Host ("  [{0}] {1} ({2}){3}" -f ($i + 1), $b.Name, $b.LastWriteTime, $info) -ForegroundColor Gray
    }

    Write-Host ""
    Write-Host "A = Restore All | 1-N = Restore Single | Q = Quit" -ForegroundColor Cyan

    if ($WhatIfPreference) {
        Write-Host "[WhatIf] Would restore backups shown above." -ForegroundColor Gray
        return
    }

    $ch = Read-Host "Choice"
    if ($ch -eq "Q") { return }

    if ($ch -eq "A") {
        foreach ($b in $baks) {
            if ($PSCmdlet.ShouldProcess($b.Name, "Restore backup")) {
                if (Restore-Backup -BackupPath $b.FullName) {
                    Remove-Item $b.FullName -Force -ErrorAction SilentlyContinue
                    Remove-Item "$($b.FullName).meta" -Force -ErrorAction SilentlyContinue
                }
            }
        }
        return
    }

    $n = 0
    if ([int]::TryParse($ch, [ref]$n)) {
        $ix = $n - 1
        if ($ix -ge 0 -and $ix -lt $baks.Count) {
            if ($PSCmdlet.ShouldProcess($baks[$ix].Name, "Restore backup")) {
                if (Restore-Backup -BackupPath $baks[$ix].FullName) {
                    Remove-Item $baks[$ix].FullName -Force -ErrorAction SilentlyContinue
                    Remove-Item "$($baks[$ix].FullName).meta" -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }
}

# ============================================================
# Safe Clean Engine
# ============================================================
function Invoke-SafeClean {
    param([array]$items, [array]$OnlyPaths = $null, [switch]$NonInteractive)
    Write-Log "INFO" "===== Safe Clean (Green only) ====="
    $green = $items | Where-Object { $_.SafetyLevel -eq "Green" }
    Write-Log "INFO" ("Green items: {0}" -f $green.Count)

    if ($green.Count -eq 0) {
        Write-Host "No green items to clean." -ForegroundColor Yellow
        return
    }

    $i = 0
    foreach ($it in $green) {
        $i++
        if ($OnlyPaths) {
            # 路径归一化（去尾斜杠+小写）：修复前精确比较，前端传尾斜杠/大小写差异会静默跳过
            $np2 = $it.FullPath.TrimEnd('\').ToLower()
            $inList = @($OnlyPaths | Where-Object { $_.TrimEnd('\').ToLower() -eq $np2 }).Count -gt 0
            if (-not $inList) { continue }
        }
        $msg1 = "[{0}/{1}] Cleaning: {2} ({3} MB)" -f $i, $green.Count, $it.FullPath, $it.SizeMB
        Write-Host $msg1 -ForegroundColor Cyan

        # -WhatIf 必须无条件生效：修复前 -NonInteractive 会短路 ShouldProcess，
        # 导致 -WhatIf -NonInteractive 组合真实执行删除。
        if (-not $PSCmdlet.ShouldProcess($it.FullPath, "Delete directory")) {
            continue
        }

        $bp = Backup-Item -Path $it.FullPath
        if (-not $bp) {
            Write-Log "WARN" ("Backup failed, skipping: {0}" -f $it.FullPath)
            $Stats.Skipped++
            continue
        }
        $dr = Remove-DirTolerant -Path $it.FullPath
        if ($dr.kept -eq 0) {
            # kept=0 即已全部清空（空目录 deleted 也是 0，但内容已被删除，不得误报失败）
            Write-Log "SUCCESS" ("Cleaned: {0} ({1} deleted)" -f $it.FullPath, $dr.deleted)
            $Stats.Cleaned++
        } elseif ($dr.deleted -gt 0) {
            Write-Log "WARN" ("Cleaned (partial): {0} ({1} deleted, {2} in-use kept)" -f $it.FullPath, $dr.deleted, $dr.kept)
            $Stats.Cleaned++
        } else {
            Write-Log "WARN" ("Not cleaned: {0} ({1} items locked or no permission)" -f $it.FullPath, $dr.kept)
            $Stats.Skipped++
        }
    }
    Write-Log "SUCCESS" ("Safe clean done: {0} cleaned, {1} skipped" -f $Stats.Cleaned, $Stats.Skipped)
}

function Invoke-DeepClean {
    param([array]$items, [array]$OnlyPaths = $null, [switch]$NonInteractive)
    Write-Log "INFO" "===== Deep Clean (Green + Yellow) ====="
    $cleanable = $items | Where-Object { $_.SafetyLevel -in @("Green", "Yellow") }
    Write-Log "INFO" ("Cleanable items: {0}" -f $cleanable.Count)

    if ($cleanable.Count -eq 0) {
        Write-Host "No items to clean." -ForegroundColor Yellow
        return
    }

    $i = 0
    foreach ($it in $cleanable) {
        $i++
        if ($OnlyPaths) {
            # 路径归一化（去尾斜杠+小写）：修复前精确比较，前端传尾斜杠/大小写差异会静默跳过
            $np2 = $it.FullPath.TrimEnd('\').ToLower()
            $inList = @($OnlyPaths | Where-Object { $_.TrimEnd('\').ToLower() -eq $np2 }).Count -gt 0
            if (-not $inList) { continue }
        }
        $isGreen = $it.SafetyLevel -eq "Green"
        $pfx = if ($isGreen) { "[Safe]" } else { "[Confirm]" }
        $clr = if ($isGreen) { "Green" } else { "Yellow" }

        $msgPath = "{0} [{1}/{2}] {3}" -f $pfx, $i, $cleanable.Count, $it.FullPath
        Write-Host $msgPath -ForegroundColor $clr

        $msgInfo = "  Size: {0} MB | Files: {1} | User: {2}" -f $it.SizeMB, $it.FileCount, $it.User
        Write-Host $msgInfo -ForegroundColor Gray

        Write-Host ("  Reason: {0}" -f $it.SafetyReason) -ForegroundColor Gray
        if ($it.Software) {
            $msgSW = "  Software: {0} | Category: {1}" -f $it.Software.name, $it.Software.category
            Write-Host $msgSW -ForegroundColor Gray
        }

        if ($isGreen -and $Config.auto_confirm_green) {
            if ($WhatIfPreference) {
                Write-Host "  [WhatIf] Would clean green item." -ForegroundColor Gray
            } else {
                Write-Host "  [Auto] Cleaning green item..." -ForegroundColor Green
            }
        } else {
            if ($WhatIfPreference) {
                Write-Host "  [WhatIf] Would clean this item." -ForegroundColor Gray
                continue
            }
            if ($NonInteractive) {
                # Web 前端已确认，非交互执行
            } else {
                $resp = Read-Host "  Clean? (Y/n/q)"
                if ($resp -eq "q") { break }
                if ($resp -notin @("", "y", "Y", "yes")) {
                    Write-Log "INFO" ("User skipped: {0}" -f $it.FullPath)
                    $Stats.Skipped++
                    continue
                }
            }
        }

        # -WhatIf 必须无条件生效：修复前 -NonInteractive 会短路 ShouldProcess，
        # 导致 -WhatIf -NonInteractive 组合真实执行删除。
        if (-not $PSCmdlet.ShouldProcess($it.FullPath, "Delete directory")) {
            continue
        }

        $bp = Backup-Item -Path $it.FullPath
        if (-not $bp) {
            Write-Log "WARN" ("Backup failed, skipping: {0}" -f $it.FullPath)
            $Stats.Skipped++
            continue
        }
        $dr = Remove-DirTolerant -Path $it.FullPath
        if ($dr.kept -eq 0) {
            # kept=0 即已全部清空（空目录 deleted 也是 0，但内容已被删除，不得误报失败）
            Write-Log "SUCCESS" ("Cleaned: {0} ({1} deleted)" -f $it.FullPath, $dr.deleted)
            $Stats.Cleaned++
        } elseif ($dr.deleted -gt 0) {
            Write-Log "WARN" ("Cleaned (partial): {0} ({1} deleted, {2} in-use kept)" -f $it.FullPath, $dr.deleted, $dr.kept)
            $Stats.Cleaned++
        } else {
            Write-Log "WARN" ("Not cleaned: {0} ({1} items locked or no permission)" -f $it.FullPath, $dr.kept)
            $Stats.Skipped++
        }
    }
    Write-Log "SUCCESS" ("Deep clean done: {0} cleaned, {1} skipped" -f $Stats.Cleaned, $Stats.Skipped)
}

# ============================================================
# Directory Junction Migration Engine
# ============================================================
function Start-DirMigration {
    param([array]$items, [string]$targetDrive)
    Write-Log "INFO" "===== Directory Junction Migration ====="
    $targetRoot = "{0}:\C_Cleaner_Migrated" -f $targetDrive
    Write-Log "INFO" ("Target: {0}" -f $targetRoot)

    if (-not (Test-Path $targetRoot)) {
        New-Item -Path $targetRoot -ItemType Directory -Force | Out-Null
    }

    $mig = $items | Where-Object { $_.SafetyLevel -in @("Green", "Yellow") -and $_.SizeMB -gt 100 } |
           Sort-Object -Property SizeBytes -Descending

    Write-Host ""
    Write-Host "===== Migratable Directories (over 100 MB) =====" -ForegroundColor Cyan

    $limit = [math]::Min(30, $mig.Count)
    for ($i = 0; $i -lt $limit; $i++) {
        $it = $mig[$i]
        $dp = $it.FullPath
        if ($dp.Length -gt 58) { $dp = "..." + $dp.Substring($dp.Length - 55) }
        $row = "[{0}] {1,-60} {2,10} MB  {3,-8} {4}" -f ($i + 1), $dp, $it.SizeMB, $it.SafetyLevel, $it.User
        Write-Host $row
    }

    Write-Host ""
    if ($WhatIfPreference) {
        Write-Host "[WhatIf] Migration candidates listed above. No action taken." -ForegroundColor Gray
        return
    }

    Write-Host "Enter number, 'A' for all, 'Q' to quit" -ForegroundColor Cyan
    $ch = Read-Host "Choice"
    if ($ch -eq "Q") { return }

    $toMig = @()
    if ($ch -eq "A") {
        $toMig = $mig
    } else {
        $n = 0
        if ([int]::TryParse($ch, [ref]$n) -and $n -ge 1 -and $n -le $mig.Count) {
            $toMig = @($mig[$n - 1])
        }
    }

    foreach ($it in $toMig) {
        Migrate-SingleItem -Item $it -TargetRoot $targetRoot
    }
}

function Migrate-SingleItem {
    param($Item, [string]$TargetRoot)

    $src = $Item.FullPath
    $rel = $src.Substring($SystemDrive.Length)
    $dst = Join-Path $TargetRoot $rel
    $dstParent = Split-Path $dst -Parent

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Log "INFO" ("Migrating: {0} -> {1}" -f $src, $dst)
    Write-Host ("  Source: {0}" -f $src) -ForegroundColor White
    Write-Host ("  Target: {0}" -f $dst) -ForegroundColor White
    Write-Host ("  Size: {0} MB | Files: {1}" -f $Item.SizeMB, $Item.FileCount) -ForegroundColor White

    if (-not $PSCmdlet.ShouldProcess($src, "Migrate directory via junction")) {
        return
    }

    try {
        Write-Host "[1/6] Creating target directory structure..." -ForegroundColor Gray
        if (-not (Test-Path $dstParent)) {
            New-Item -Path $dstParent -ItemType Directory -Force | Out-Null
        }

        Write-Host "[2/6] robocopy copying files..." -ForegroundColor Gray
        $rcArgs = @(
            $src, $dst, "/E", "/COPY:DAT", "/DCOPY:T",
            "/R:$($Config.robocopy_retry)", "/W:$($Config.robocopy_wait)",
            "/MT:8", "/NP", "/NFL", "/NDL"
        )
        $rcRes = & robocopy @rcArgs
        if ($LASTEXITCODE -ge 8) {
            Write-Log "ERROR" ("robocopy failed with exit code {0}" -f $LASTEXITCODE)
            $rcRes | Select-Object -Last 5 | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
            return
        }

        Write-Host "[3/6] Verifying file integrity (sampling)..." -ForegroundColor Gray
        $sampleCount = [math]::Min($Config.sample_verification_count, $Item.FileCount)
        $samples = @()
        if ($sampleCount -gt 0) {
            $samples = Get-ChildItem $src -Recurse -File -ErrorAction SilentlyContinue |
                       Get-Random -Count $sampleCount
        }
        $bad = 0
        foreach ($sf in $samples) {
            $rf = $sf.FullName.Substring($src.Length)
            $df = Join-Path $dst $rf
            if (Test-Path $df) {
                $sh = (Get-FileHash $sf.FullName -Algorithm SHA256).Hash
                $dh = (Get-FileHash $df -Algorithm SHA256).Hash
                if ($sh -ne $dh) {
                    $bad++
                    Write-Log "ERROR" ("Hash mismatch: {0}" -f $sf.Name)
                }
            }
        }
        if ($bad -gt 0) {
            Write-Log "ERROR" ("Verification failed: {0} files mismatch" -f $bad)
            Write-Host "Migration aborted. Target directory kept for inspection." -ForegroundColor Red
            return
        }
        Write-Host "  Verification passed." -ForegroundColor Green

        Write-Host "[4/6] Incremental sync (catching late changes)..." -ForegroundColor Gray
        $mirArgs = @(
            $src, $dst, "/MIR", "/COPY:DAT", "/DCOPY:T",
            "/R:1", "/W:1", "/MT:4", "/NP", "/NFL", "/NDL"
        )
        $mirRes = & robocopy @mirArgs
        if ($LASTEXITCODE -ge 8) {
            Write-Log "ERROR" ("Incremental robocopy failed with exit code {0}" -f $LASTEXITCODE)
            Write-Host "Migration aborted during incremental sync." -ForegroundColor Red
            return
        }

        Write-Host "[5/6] Backing up original directory (.bak)..." -ForegroundColor Gray
        $bakSrc = "$src.bak"
        if (Test-Path $bakSrc) {
            Remove-Item $bakSrc -Recurse -Force -ErrorAction Stop
        }
        Rename-Item $src -NewName "$($Item.Name).bak" -ErrorAction Stop

        Write-Host "[6/6] Creating mklink /J junction..." -ForegroundColor Gray
        $mlArgs = @("/J", $src, $dst)
        $mlRes = & cmd /c mklink $mlArgs 2>&1
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $src) -or -not (Test-Path $bakSrc)) {
            # 修复前 mklink 失败不校验仍报 SUCCESS：原目录已改名 .bak、原路径消失且无
            # 联接 → 软件找不到数据目录。失败必须回滚 Rename-Item。
            Write-Log "ERROR" ("mklink failed: {0} (exit {1})" -f $mlRes, $LASTEXITCODE)
            Write-Host ("  {0}" -f $mlRes) -ForegroundColor Red
            try {
                if (Test-Path $bakSrc) {
                    Rename-Item $bakSrc -NewName "$($Item.Name)" -ErrorAction Stop
                    Write-Log "WARN" ("Rolled back: {0} renamed back" -f $bakSrc)
                    Write-Host "  Rolled back: original directory restored." -ForegroundColor Yellow
                }
            } catch {
                Write-Log "ERROR" ("Rollback failed: {0} - {1} (manual restore needed)" -f $bakSrc, $_.Exception.Message)
            }
            return
        }
        Write-Host ("  {0}" -f $mlRes) -ForegroundColor Green

        $Stats.Migrated++
        Write-Log "SUCCESS" ("Migration complete: {0} -> {1}" -f $src, $dst)
        Write-Host "SUCCESS! Migration complete." -ForegroundColor Green
        Write-Host ("  Backup: {0}" -f $bakSrc) -ForegroundColor Gray
        Write-Host ("  Junction: {0} -> {1}" -f $src, $dst) -ForegroundColor Gray
        Write-Host "  (After confirming apps work normally, delete the .bak backup)" -ForegroundColor Gray

    } catch {
        Write-Log "ERROR" ("Migration error: {0}" -f $_.Exception.Message)
        Write-Host ("Migration failed: {0}" -f $_.Exception.Message) -ForegroundColor Red
    }
}

# ============================================================
# Multi-User Support
# ============================================================
function Get-AllUserProfiles {
    $skip = $Config.excluded_users + @("desktop.ini")
    $dirs = Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notin $skip -and -not $_.Name.EndsWith('$') }
    Write-Log "INFO" ("Users found: {0} ({1})" -f $dirs.Count, ($dirs.Name -join ', '))
    return $dirs
}

# ============================================================
# Uninstall Residue Scan & Clean (卸载残留扫描与清理)
# ============================================================
function Get-InstalledApps {
    # 从注册表读取已安装程序列表（过滤系统组件）
    $apps = [System.Collections.ArrayList]::new()
    $hives = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
    )
    foreach ($h in $hives) {
        Get-ChildItem $h -ErrorAction SilentlyContinue | ForEach-Object {
            $props = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
            if (-not $props) { return }
            if ($props.SystemComponent -eq 1) { return }
            if ($props.ParentKeyName) { return }
            if (-not $props.DisplayName) { return }
            [void]$apps.Add([PSCustomObject]@{
                DisplayName     = [string]$props.DisplayName
                Publisher       = [string]$props.Publisher
                InstallLocation = [string]$props.InstallLocation
                UninstallString = [string]$props.UninstallString
                KeyPath         = ($_.PSPath -replace '^.*?Registry::', '')
                KeyName         = $_.PSChildName
                Hive            = if ($_.PSPath -like 'HKCU:*') { "HKCU" } else { "HKLM" }
            })
        }
    }
    return $apps
}

function Get-UninstallDir {
    # 从 UninstallString 提取 exe 所在目录
    param([string]$s)
    if (-not $s) { return $null }
    if ($s -match 'msiexec') { return $null }
    $exe = $null
    if ($s -match '"([^"]+\.exe)"') { $exe = $Matches[1] }
    elseif ($s -match '^([A-Za-z]:\\.*?\.exe)') { $exe = $Matches[1] }
    else { return $null }
    $d = Split-Path $exe -Parent
    if ($d) { return $d }
    return $null
}

function Invoke-ResidueScan {
    Write-Log "INFO" "===== Uninstall Residue Scan ====="
    $results = [System.Collections.ArrayList]::new()
    $apps = @(Get-InstalledApps)
    Write-Log "INFO" ("Installed apps found: {0}" -f $apps.Count)
    $appNames = @{}
    foreach ($a in $apps) {
        $n = $a.DisplayName.ToLower()
        if (-not $appNames.ContainsKey($n)) { $appNames[$n] = $true }
    }

    # --- A. 注册表卸载条目残留（指向的目录已不存在） ---
    $regCnt = 0
    foreach ($a in $apps) {
        $paths = @()
        if ($a.InstallLocation) { $paths += $a.InstallLocation }
        $ud = Get-UninstallDir -s $a.UninstallString
        if ($ud) { $paths += $ud }
        if ($paths.Count -eq 0) { continue }
        # 跳过含环境变量 / 网络路径的条目（无法可靠判断）
        $okPaths = @($paths | Where-Object { $_ -and -not ($_ -match '^\\\\') -and -not ($_ -match '%') })
        if ($okPaths.Count -eq 0) { continue }
        $exists = $false
        foreach ($p in $okPaths) { if (Test-Path $p) { $exists = $true; break } }
        if (-not $exists) {
            $regCnt++
            $reason = "软件已卸载，但注册表卸载条目仍残留"
            if ($a.InstallLocation) { $reason += "（指向 $($a.InstallLocation)，目录已不存在）" }
            [void]$results.Add([PSCustomObject]@{
                id = "reg:" + $a.KeyPath
                type = "registry"
                name = $a.DisplayName
                path = $a.KeyPath
                sizeBytes = 0
                sizeMB = 0
                fileCount = 0
                level = "Yellow"
                reason = $reason
                detail = "发布者: $($a.Publisher) | 注册表: $($a.Hive) | 键名: $($a.KeyName) | 卸载命令: $($a.UninstallString)"
                lastModified = ""
            })
        }
    }
    Write-Log "INFO" ("Registry residue entries: {0}" -f $regCnt)

    # --- B. Program Files 孤儿目录（注册表无对应已安装软件） ---
    $pfRoots = @($env:ProgramFiles, ${env:ProgramFiles(x86)})
    $pfSkip = @("Microsoft", "Common Files", "Windows Defender", "Windows Kits",
                "Internet Explorer", "Uninstall Information", "Package Cache",
                "Windows NT", "Reference Assemblies", "NuGet", "Windows Mail",
                "Windows Photo Viewer", "Windows Portable Devices")
    foreach ($pf in $pfRoots) {
        if (-not $pf -or -not (Test-Path $pf)) { continue }
        Get-ChildItem $pf -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $dn = $_.Name
            if ($dn -in $pfSkip) { return }
            if ($dn -match '^\{|^Microsoft\.') { return }
            if (Test-IsExcluded -Path $_.FullName) { return }
            if (Find-KnownSoftware -Path $_.FullName) { return }
            # 与已安装列表比对：InstallLocation / 卸载命令目录 / DisplayName 名称
            $pfDir = $_.FullName
            $rel = $apps | Where-Object {
                ($_.InstallLocation -and $_.InstallLocation.ToLower().StartsWith($pfDir.ToLower())) -or
                ($_.DisplayName -and $_.DisplayName.ToLower().Contains($dn.ToLower()))
            }
            $matchApp = @($apps | Where-Object { $_.DisplayName.ToLower().Contains($dn.ToLower()) })
            $ud2 = $null
            if ($matchApp.Count -gt 0) { $ud2 = Get-UninstallDir -s $matchApp[0].UninstallString }
            if ($ud2 -and $ud2.ToLower().StartsWith($pfDir.ToLower())) { return }
            if ($rel) { return }
            $files = @(Get-ChildItem $_.FullName -Recurse -File -ErrorAction SilentlyContinue)
            $sz = ($files | Measure-Object -Property Length -Sum).Sum
            if (-not $sz -or $sz -lt (20MB)) { return }
            [void]$results.Add([PSCustomObject]@{
                id = "folder:" + $_.FullName
                type = "folder"
                name = $dn
                path = $_.FullName
                sizeBytes = $sz
                sizeMB = [math]::Round($sz / 1MB, 2)
                fileCount = $files.Count
                level = "Yellow"
                reason = "疑似卸载残留：Program Files 目录但注册表无对应软件记录"
                detail = "最后写入: $($_.LastWriteTime.ToString('yyyy-MM-dd HH:mm'))。若该软件仍在使用请勿清理。"
                lastModified = $_.LastWriteTime.ToString("yyyy-MM-dd HH:mm")
            })
        }
    }

    # --- C. 开始菜单失效快捷方式 ---
    $smRoots = @(
        "$env:ProgramData\Microsoft\Windows\Start Menu\Programs",
        "$env:APPDATA\Microsoft\Windows\Start Menu\Programs"
    )
    $sh = $null
    $lnkCnt = 0
    foreach ($smr in $smRoots) {
        if (-not (Test-Path $smr)) { continue }
        Get-ChildItem $smr -Recurse -Filter *.lnk -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                if (-not $sh) { $sh = New-Object -ComObject WScript.Shell }
                $t = $sh.CreateShortcut($_.FullName).TargetPath
                if ($t -and -not (Test-Path $t)) {
                    $lnkCnt++
                    [void]$results.Add([PSCustomObject]@{
                        id = "lnk:" + $_.FullName
                        type = "shortcut"
                        name = $_.BaseName
                        path = $_.FullName
                        sizeBytes = 0
                        sizeMB = 0
                        fileCount = 0
                        level = "Green"
                        reason = "开始菜单快捷方式指向的目标已不存在（软件已卸载）"
                        detail = "目标: $t"
                        lastModified = $_.LastWriteTime.ToString("yyyy-MM-dd HH:mm")
                    })
                }
            } catch { }
        }
    }
    Write-Log "INFO" ("Dead shortcuts: {0}" -f $lnkCnt)

    # --- D. AppData 数据残留（软件已卸载但数据/缓存还在，且超过90天未更新） ---
    $adCnt = 0
    $oldCutoff = (Get-Date).AddDays(-90)
    $userDirs = Get-AllUserProfiles
    foreach ($ud in $userDirs) {
        foreach ($base in @("AppData\Local", "AppData\Roaming", "AppData\LocalLow")) {
            $basePath = Join-Path $ud.FullName $base
            if (-not (Test-Path $basePath)) { continue }
            Get-ChildItem $basePath -Directory -Depth 1 -ErrorAction SilentlyContinue | ForEach-Object {
                if ($_.LastWriteTime -gt $oldCutoff) { return }
                $sw = Find-KnownSoftware -Path $_.FullName
                if (-not $sw) { return }
                $swName = $sw.name.ToLower()
                $installed = @($appNames.Keys | Where-Object { $_.Contains($swName) -or $swName.Contains($_) })
                if ($installed.Count -gt 0) { return }
                $files = @(Get-ChildItem $_.FullName -Recurse -File -ErrorAction SilentlyContinue)
                $sz = ($files | Measure-Object -Property Length -Sum).Sum
                if (-not $sz -or $sz -lt (20MB)) { return }
                $adCnt++
                [void]$results.Add([PSCustomObject]@{
                    id = "appdata:" + $_.FullName
                    type = "appdata"
                    name = $_.Name
                    path = $_.FullName
                    sizeBytes = $sz
                    sizeMB = [math]::Round($sz / 1MB, 2)
                    fileCount = $files.Count
                    level = "Yellow"
                    reason = "软件 ( $($sw.name) ) 已不在已安装列表，数据/缓存仍残留（超过90天未更新）"
                    detail = "用户: $($ud.Name) | 知识库类别: $($sw.category)"
                    lastModified = $_.LastWriteTime.ToString("yyyy-MM-dd HH:mm")
                })
            }
        }
    }
    Write-Log "INFO" ("AppData leftovers: {0}" -f $adCnt)

    # --- E. Windows 系统残留 ---
    $sysPaths = @(
        "$env:SystemRoot\Temp",
        "$env:SystemRoot\SoftwareDistribution\Download",
        "$env:SystemRoot\Prefetch"
    )
    foreach ($sp in $sysPaths) {
        if (-not (Test-Path $sp)) { continue }
        $files = @(Get-ChildItem $sp -Recurse -File -ErrorAction SilentlyContinue)
        $sz = ($files | Measure-Object -Property Length -Sum).Sum
        if (-not $sz -or $sz -lt (20MB)) { continue }
        [void]$results.Add([PSCustomObject]@{
            id = "system:" + $sp
            type = "system"
            name = Split-Path $sp -Leaf
            path = $sp
            sizeBytes = $sz
            sizeMB = [math]::Round($sz / 1MB, 2)
            fileCount = $files.Count
            level = "Green"
            reason = "Windows 系统残留（更新缓存/预读/临时文件），系统会自动重建"
            detail = ""
            lastModified = ""
        })
    }

    $totalMB = ($results | Measure-Object -Property sizeMB -Sum).Sum
    Write-Log "SUCCESS" ("Residue scan complete: {0} items, {1} MB" -f $results.Count, [math]::Round($totalMB, 2))
    return @($results | Sort-Object sizeMB -Descending)
}

function Invoke-ResidueClean {
    param([array]$items)
    Write-Log "INFO" "===== Uninstall Residue Clean ====="
    if (-not $items -or $items.Count -eq 0) {
        Write-Host "No residue items to clean." -ForegroundColor Yellow
        return
    }
    Write-Log "INFO" ("Residue items to clean: {0}" -f $items.Count)
    foreach ($it in $items) {
        $type = [string]$it.type
        $p = [string]$it.path
        $name = [string]$it.name
        Write-Host ("[{0}] {1} - {2}" -f $type, $name, $p) -ForegroundColor Cyan
        if ($WhatIfPreference) {
            # 修复前残留清理无 WhatIf 守卫，-WhatIf 仍会真实删除
            Write-Host ("  [WhatIf] Would clean residue: {0}" -f $p) -ForegroundColor Gray
            continue
        }
        switch ($type) {
            "shortcut" {
                if (Test-Path $p) {
                    try {
                        Remove-Item $p -Force -ErrorAction Stop
                        Write-Log "SUCCESS" ("Removed dead shortcut: {0}" -f $p)
                        $Stats.Cleaned++
                    } catch {
                        # 单个失败不得中止整个任务（修复前 -ErrorAction Stop 会直接中断全部清理）
                        Write-Log "ERROR" ("Shortcut remove failed: {0} - {1}" -f $p, $_.Exception.Message)
                        $Stats.Skipped++
                    }
                }
            }
            "registry" {
                $regFull = "Registry::$p"
                if (Test-Path $regFull) {
                    try {
                        if (-not (Test-Path $BackupDir)) { New-Item $BackupDir -ItemType Directory -Force | Out-Null }
                        $regBackup = Join-Path $BackupDir ("residue_reg_{0}_{1}.reg" -f ($name -replace '[^\w\-]', '_'), (Get-Date -Format "yyyyMMdd_HHmmss"))
                        & reg.exe export $p $regBackup /y 2>&1 | Out-Null
                        if (-not (Test-Path $regBackup)) {
                            # 修复前备份失败仍删除注册表键，卸载条目被删且无 .reg 备份不可恢复
                            Write-Log "ERROR" ("Registry backup failed, skipping: {0}" -f $p)
                            $Stats.Skipped++
                            continue
                        }
                        Write-Log "INFO" ("Registry backup: {0}" -f $regBackup)
                        Remove-Item $regFull -Recurse -Force -ErrorAction Stop
                        Write-Log "SUCCESS" ("Removed registry residue: {0}" -f $p)
                        $Stats.Cleaned++
                    } catch {
                        Write-Log "ERROR" ("Registry residue remove failed: {0} - {1}" -f $p, $_.Exception.Message)
                        $Stats.Skipped++
                    }
                }
            }
            default {
                # folder / appdata / system
                if (Test-Path $p) {
                    if (-not (Test-IsLockedByProcess -Path $p -Procs $RunningProcesses)) {
                        $bp = Backup-Item -Path $p
                        if ($bp) {
                            $dr = Remove-DirTolerant -Path $p
                            if ($dr.kept -eq 0) {
                                Write-Log "SUCCESS" ("Removed residue folder: {0} ({1} deleted)" -f $p, $dr.deleted)
                                $Stats.Cleaned++
                            } elseif ($dr.deleted -gt 0) {
                                Write-Log "WARN" ("Removed residue folder (partial): {0} ({1} deleted, {2} kept)" -f $p, $dr.deleted, $dr.kept)
                                $Stats.Cleaned++
                            } else {
                                # 全被占用或权限不足（如非管理员删 C:\Windows 下目录）
                                Write-Log "WARN" ("Residue folder not removed: {0} ({1} items locked or no permission)" -f $p, $dr.kept)
                                $Stats.Skipped++
                            }
                        } else {
                            $Stats.Skipped++
                        }
                    } else {
                        Write-Log "WARN" ("Skipped (in use): {0}" -f $p)
                        $Stats.Skipped++
                    }
                }
            }
        }
    }
    Write-Log "SUCCESS" ("Residue clean done: {0} cleaned, {1} skipped" -f $Stats.Cleaned, $Stats.Skipped)
}

# ============================================================
# JSON Export (供 Web 前端使用)
# ============================================================
function Export-ResultJson {
    param([array]$items, [string]$path)
    $jParent = Split-Path $path -Parent
    if ($jParent -and -not (Test-Path $jParent)) { New-Item -Path $jParent -ItemType Directory -Force | Out-Null }
    $drv = Get-PSDrive -Name $SystemDrive.Replace(':', '')
    $totalGB = [math]::Round(($drv.Used + $drv.Free) / 1GB, 2)
    $freeGB = [math]::Round($drv.Free / 1GB, 2)
    $usedGB = [math]::Round($drv.Used / 1GB, 2)
    $green = @($items | Where-Object { $_.SafetyLevel -eq "Green" })
    $yellow = @($items | Where-Object { $_.SafetyLevel -eq "Yellow" })
    $red = @($items | Where-Object { $_.SafetyLevel -eq "Red" })
    $cleanableGB = [math]::Round((@($green + $yellow) | Measure-Object -Property SizeBytes -Sum).Sum / 1GB, 2)

    $obj = [PSCustomObject]@{
        timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        type = "scan"
        drive = [PSCustomObject]@{
            letter = $SystemDrive
            totalGB = $totalGB
            usedGB = $usedGB
            freeGB = $freeGB
            usedPercent = if ($totalGB -gt 0) { [math]::Round($usedGB / $totalGB * 100, 1) } else { 0 }
        }
        stats = [PSCustomObject]@{
            total = $items.Count
            totalGB = [math]::Round(($items | Measure-Object -Property SizeBytes -Sum).Sum / 1GB, 2)
            green = $green.Count
            yellow = $yellow.Count
            red = $red.Count
            cleanableGB = $cleanableGB
        }
        items = @($items | ForEach-Object {
            [PSCustomObject]@{
                path = $_.FullPath
                name = $_.Name
                user = $_.User
                sizeMB = $_.SizeMB
                sizeBytes = $_.SizeBytes
                fileCount = $_.FileCount
                level = $_.SafetyLevel
                reason = $_.SafetyReason
                software = if ($_.Software) { $_.Software.name } else { "" }
                category = if ($_.Software) { $_.Software.category } else { "" }
                lastModified = if ($_.LastModified) { $_.LastModified.ToString("yyyy-MM-dd HH:mm") } else { "" }
            }
        })
    }
    try {
        $obj | ConvertTo-Json -Depth 6 | Set-Content $path -Encoding UTF8
        Write-Log "SUCCESS" ("JSON exported: {0}" -f $path)
    } catch {
        Write-Log "ERROR" ("JSON export failed: {0}" -f $_.Exception.Message)
    }
}

function Export-ResidueJson {
    param([array]$items, [string]$path)
    $jParent = Split-Path $path -Parent
    if ($jParent -and -not (Test-Path $jParent)) { New-Item -Path $jParent -ItemType Directory -Force | Out-Null }
    $obj = [PSCustomObject]@{
        timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        type = "residue"
        stats = [PSCustomObject]@{
            total = $items.Count
            green = @($items | Where-Object { $_.level -eq "Green" }).Count
            yellow = @($items | Where-Object { $_.level -eq "Yellow" }).Count
            totalMB = [math]::Round(($items | Measure-Object -Property sizeMB -Sum).Sum, 2)
        }
        items = @($items | ForEach-Object {
            [PSCustomObject]@{
                id = $_.id
                type = $_.type
                name = $_.name
                path = $_.path
                sizeMB = $_.sizeMB
                sizeBytes = $_.sizeBytes
                fileCount = $_.fileCount
                level = $_.level
                reason = $_.reason
                detail = $_.detail
                lastModified = $_.lastModified
            }
        })
    }
    try {
        $obj | ConvertTo-Json -Depth 6 | Set-Content $path -Encoding UTF8
        Write-Log "SUCCESS" ("Residue JSON exported: {0}" -f $path)
    } catch {
        Write-Log "ERROR" ("Residue JSON export failed: {0}" -f $_.Exception.Message)
    }
}

# ============================================================
# HTML Report Export
# ============================================================
function Export-Report {
    param([array]$items, [string]$reportPath)
    Write-Log "INFO" ("Exporting report: {0}" -f $reportPath)

    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $totalGB = [math]::Round($Stats.TotalSize / 1GB, 2)
    $greenGB = [math]::Round(($items | Where-Object { $_.SafetyLevel -eq "Green" } | Measure-Object -Property SizeBytes -Sum).Sum / 1GB, 2)

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("<!DOCTYPE html>")
    [void]$sb.AppendLine("<html lang='en'><head><meta charset='UTF-8'>")
    [void]$sb.AppendLine(("<title>C Drive Clean Report - {0}</title>" -f $ts))
    [void]$sb.AppendLine("<style>")
    [void]$sb.AppendLine("body{font-family:'Segoe UI',sans-serif;margin:20px;background:#1e1e1e;color:#d4d4d4}")
    [void]$sb.AppendLine("h1{color:#569cd6;border-bottom:2px solid #569cd6;padding-bottom:10px}")
    [void]$sb.AppendLine("h2{color:#4ec9b0;margin-top:30px}")
    [void]$sb.AppendLine(".sum{display:flex;gap:20px;margin:20px 0;flex-wrap:wrap}")
    [void]$sb.AppendLine(".card{background:#252526;border-radius:8px;padding:16px 24px;min-width:150px}")
    [void]$sb.AppendLine(".card .v{font-size:28px;font-weight:bold}")
    [void]$sb.AppendLine(".card .l{font-size:12px;color:#888;margin-top:4px}")
    [void]$sb.AppendLine(".g .v{color:#4ec9b0}.y .v{color:#dcdcaa}.r .v{color:#f44747}")
    [void]$sb.AppendLine("table{width:100%;border-collapse:collapse;margin-top:10px}")
    [void]$sb.AppendLine("th{background:#333;color:#569cd6;padding:10px;text-align:left}")
    [void]$sb.AppendLine("td{padding:8px 10px;border-bottom:1px solid #333;font-size:13px}")
    [void]$sb.AppendLine("tr:hover{background:#2a2d2e}")
    [void]$sb.AppendLine(".path{font-family:Consolas,monospace;font-size:11px;max-width:400px;word-break:break-all}")
    [void]$sb.AppendLine(".ft{margin-top:30px;padding-top:10px;border-top:1px solid #333;color:#666;font-size:11px}")
    [void]$sb.AppendLine("</style></head><body>")
    [void]$sb.AppendLine("<h1>C Drive Clean Report</h1>")
    [void]$sb.AppendLine(("<p>Generated: {0} | System Drive: {1}</p>" -f $ts, $SystemDrive))

    [void]$sb.AppendLine("<div class='sum'>")
    [void]$sb.AppendLine(("<div class='card'><div class='v'>{0}</div><div class='l'>Items Scanned</div></div>" -f $Stats.TotalScanned))
    [void]$sb.AppendLine(("<div class='card g'><div class='v'>{0} GB</div><div class='l'>Recoverable</div></div>" -f $totalGB))
    [void]$sb.AppendLine(("<div class='card g'><div class='v'>{0}</div><div class='l'>Green (Safe)</div></div>" -f $Stats.GreenItems))
    [void]$sb.AppendLine(("<div class='card y'><div class='v'>{0}</div><div class='l'>Yellow (Review)</div></div>" -f $Stats.YellowItems))
    [void]$sb.AppendLine(("<div class='card r'><div class='v'>{0}</div><div class='l'>Red (Protected)</div></div>" -f $Stats.RedItems))
    [void]$sb.AppendLine("</div>")

    function BuildTable($title, $filteredItems, $columns, $col6 = $null) {
        [void]$sb.AppendLine("<h2>$title</h2>")
        [void]$sb.AppendLine("<table><tr>")
        foreach ($c in $columns) { [void]$sb.AppendLine("<th>$c</th>") }
        [void]$sb.AppendLine("</tr>")
        $idx = 0
        foreach ($fi in $filteredItems) {
            $idx++
            $tr = "<tr><td>{0}</td><td class='path'>{1}</td><td>{2}</td><td>{3}</td><td>{4}</td>" -f $idx, $fi.FullPath, $fi.SizeMB, $fi.FileCount, $fi.User
            if ($columns.Count -gt 5) {
                # 修复前第 6 列表头是 "Reason" 但单元格填 Software.name，表头内容错位
                $v6 = if ($col6) { & $col6 $fi } else { "-" }
                $tr += "<td>{0}</td>" -f $v6
            }
            $tr += "</tr>"
            [void]$sb.AppendLine($tr)
        }
        [void]$sb.AppendLine("</table>")
    }

    $greenItems = $items | Where-Object { $_.SafetyLevel -eq "Green" }
    $title1 = "Green - Safe ({0} items, {1} GB)" -f $greenItems.Count, $greenGB
    BuildTable $title1 $greenItems @("#", "Directory", "Size(MB)", "Files", "User", "Software") { param($fi) if ($fi.Software) { $fi.Software.name } else { "-" } }

    $yellowItems = $items | Where-Object { $_.SafetyLevel -eq "Yellow" }
    $yellowGB = [math]::Round(($yellowItems | Measure-Object -Property SizeBytes -Sum).Sum / 1GB, 2)
    $title2 = "Yellow - Review ({0} items, {1} GB)" -f $yellowItems.Count, $yellowGB
    BuildTable $title2 $yellowItems @("#", "Directory", "Size(MB)", "Files", "User", "Reason") { param($fi) $fi.SafetyReason }

    $redItems = $items | Where-Object { $_.SafetyLevel -eq "Red" }
    $title3 = "Red - Protected ({0} items)" -f $redItems.Count
    BuildTable $title3 $redItems @("#", "Directory", "Size(MB)", "Files", "User", "Reason") { param($fi) $fi.SafetyReason }

    $ftMsg = "C_Cleaner v2.0 | Cleaned: {0} | Migrated: {1} | Skipped: {2}" -f $Stats.Cleaned, $Stats.Migrated, $Stats.Skipped
    [void]$sb.AppendLine(("<div class='ft'>{0}</div>" -f $ftMsg))
    [void]$sb.AppendLine("</body></html>")

    try {
        $sb.ToString() | Set-Content $reportPath -Encoding UTF8
        Write-Log "SUCCESS" ("Report exported: {0}" -f $reportPath)
    } catch {
        Write-Log "ERROR" ("Report export failed: {0}" -f $_.Exception.Message)
    }
}

# ============================================================
# Summary Display
# ============================================================
function Show-ScanSummary {
    param([array]$items)
    Write-Host ""
    Write-Host "===== Scan Summary =====" -ForegroundColor Cyan
    Write-Host ("  Total Items: {0}" -f $Stats.TotalScanned) -ForegroundColor White
    Write-Host ("  Total Size: {0} GB" -f ([math]::Round($Stats.TotalSize / 1GB, 2))) -ForegroundColor White
    Write-Host ("  Green (Safe): {0}" -f $Stats.GreenItems) -ForegroundColor Green
    Write-Host ("  Yellow (Review): {0}" -f $Stats.YellowItems) -ForegroundColor Yellow
    Write-Host ("  Red (Protected): {0}" -f $Stats.RedItems) -ForegroundColor Red
    Write-Host ""

    Write-Host "===== Top 20 by Size =====" -ForegroundColor Cyan
    $header = "{0,-8} {1,-50} {2,10} {3,8}" -f "Level", "Name", "Size(MB)", "User"
    Write-Host $header
    Write-Host ("{0,-8} {1,-50} {2,10} {3,8}" -f "-----", "----", "--------", "----")

    $top = $items | Select-Object -First 20
    foreach ($t in $top) {
        $lv = $t.SafetyLevel.Substring(0, 1)
        $nm = $t.Name
        if ($nm.Length -gt 47) { $nm = $nm.Substring(0, 44) + "..." }
        $clr = switch ($t.SafetyLevel) { "Green" { "Green" } "Yellow" { "Yellow" } "Red" { "Red" } default { "White" } }
        $row = "{0,-8} {1,-50} {2,10} {3,8}" -f $lv, $nm, $t.SizeMB, $t.User
        Write-Host $row -ForegroundColor $clr
    }
}

# ============================================================
# Main Entry Point
# ============================================================
function Main {
    if (-not $NoBanner) {
        Write-Host ""
        Write-Host "================================================================" -ForegroundColor Cyan
        Write-Host "   C Drive Safe Cleaner v2.1" -ForegroundColor Cyan
        Write-Host "   Universal Scan | Safety Levels | Junction Migration | Restore | Residue" -ForegroundColor Cyan
        Write-Host "================================================================" -ForegroundColor Cyan
        Write-Host ""
    }

    if ($WhatIfPreference) {
        Write-Host ">>> -WhatIf MODE - No changes will be made <<<" -ForegroundColor Yellow
        Write-Host ""
    }

    Write-Log "INFO" ("C_Cleaner start | Mode: {0} | WhatIf: {1}" -f $Mode, $WhatIfPreference)

    # Disk space check
    $di = Get-PSDrive -Name $SystemDrive.Replace(':', '')
    $freeC = [math]::Round($di.Free / 1GB, 2)
    $totalC = [math]::Round(($di.Used + $di.Free) / 1GB, 2)
    Write-Log "INFO" ("C: drive - Used: {0} GB / Total: {1} GB | Free: {2} GB" -f ($totalC - $freeC), $totalC, $freeC)

    if ($Mode -eq "Migrate") {
        $td = Get-PSDrive -Name $TargetDrive -ErrorAction SilentlyContinue
        if (-not $td) {
            Write-Log "ERROR" ("Target drive {0}: not found!" -f $TargetDrive)
            return
        }
        Write-Log "INFO" ("{0}: drive free space: {1} GB" -f $TargetDrive, ([math]::Round($td.Free / 1GB, 2)))
    }

    # Initialize
    $script:RunningProcesses = Get-RunningProcesses
    Import-KnowledgeBase

    if (-not (Test-Path $BackupDir)) {
        New-Item -Path $BackupDir -ItemType Directory -Force | Out-Null
    }

    # 备份保留期清理（config.backup_retention_days，默认 90 天）——
    # 修复前配置项定义了但从未生效，backups 目录无上限增长，反向吃掉 C 盘空间
    $brd = if ($Config.backup_retention_days -and $Config.backup_retention_days -gt 0) { $Config.backup_retention_days } else { 90 }
    Get-ChildItem $BackupDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in @(".zip", ".reg") -and $_.LastWriteTime -lt (Get-Date).AddDays(-$brd) } |
        ForEach-Object {
            Write-Log "INFO" ("Removing expired backup: {0} (older than {1} days)" -f $_.Name, $brd)
            Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
            Remove-Item "$($_.FullName).meta" -Force -ErrorAction SilentlyContinue
        }

    # Load clean request (Web 前端传来的路径列表)
    $CleanReq = $null
    if ($CleanFromJson -and (Test-Path $CleanFromJson)) {
        try { $CleanReq = Get-Content $CleanFromJson -Raw -Encoding UTF8 | ConvertFrom-Json } catch {
            Write-Log "ERROR" ("Clean request parse failed: {0}" -f $_.Exception.Message)
        }
    }

    # Mode dispatch: Restore
    if ($Mode -eq "Restore") {
        if ($WhatIfPreference) {
            # 修复前 Restore 无任何 WhatIf 守卫：-WhatIf 会真实恢复并删除备份 zip
            Write-Host ("[WhatIf] Would restore: {0}" -f $(if ($RestoreBackup) { $RestoreBackup } else { "all backups" })) -ForegroundColor Yellow
            if ($ExportJson) {
                # 用 .NET 写文件而非 Set-Content：Set-Content 受 -WhatIf 传播影响会被静默抑制
                $whatIfJson = [PSCustomObject]@{
                    timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                    type = "restore"
                    ok = $false
                    whatif = $true
                    backup = $RestoreBackup
                } | ConvertTo-Json -Depth 5
                [System.IO.File]::WriteAllText($ExportJson, $whatIfJson, [System.Text.UTF8Encoding]::new($true))
            }
            return
        }
        $ok = $false
        if ($RestoreBackup) {
            $bp = Join-Path $BackupDir $RestoreBackup
            if (Test-Path $bp) {
                if (Restore-Backup -BackupPath $bp) {
                    Remove-Item $bp -Force -ErrorAction SilentlyContinue
                    Remove-Item "$bp.meta" -Force -ErrorAction SilentlyContinue
                    $ok = $true
                }
            } else {
                Write-Log "ERROR" ("Backup not found: {0}" -f $bp)
            }
        } else {
            Invoke-RestoreAll
        }
        if ($ExportJson) {
            [PSCustomObject]@{
                timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                type = "restore"
                ok = $ok
                backup = $RestoreBackup
            } | ConvertTo-Json -Depth 5 | Set-Content $ExportJson -Encoding UTF8
        }
        return
    }

    # Mode dispatch: ResidueScan / ResidueClean
    if ($Mode -eq "ResidueScan") {
        $residues = Invoke-ResidueScan
        if ($ExportJson) { Export-ResidueJson -items $residues -path $ExportJson }
        Write-Host ""
        Write-Host "===== Residue Summary =====" -ForegroundColor Cyan
        Write-Host ("  Total: {0} | Green (safe): {1} | Yellow (review): {2}" -f $residues.Count,
            (@($residues | Where-Object { $_.level -eq "Green" }).Count),
            (@($residues | Where-Object { $_.level -eq "Yellow" }).Count)) -ForegroundColor White
        return
    }
    if ($Mode -eq "ResidueClean") {
        if (-not $CleanReq -or -not $CleanReq.residues) {
            Write-Log "ERROR" "ResidueClean requires -CleanFromJson with a residues list"
            return
        }
        Invoke-ResidueClean -items $CleanReq.residues
        if ($ExportJson) {
            $obj = [PSCustomObject]@{
                timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                type = "clean"
                mode = "ResidueClean"
                stats = [PSCustomObject]@{ cleaned = $Stats.Cleaned; skipped = $Stats.Skipped; migrated = $Stats.Migrated }
            }
            $obj | ConvertTo-Json -Depth 5 | Set-Content $ExportJson -Encoding UTF8
        }
        return
    }

    # Scan
    Write-Host "Scanning..." -ForegroundColor Cyan
    $results = Invoke-Scan

    if ($results.Count -eq 0) {
        Write-Host "No items found." -ForegroundColor Yellow
        # 注意：不能在这里 return —— Web 调用方（web_server.ps1）靠 -ExportJson 结果
        # 文件判断任务成败，0 项时必须照常导出，否则前端误报"任务进程失败"。
    } else {
        Show-ScanSummary -items $results

        switch ($Mode) {
            "Scan" {
                Write-Host ""
                Write-Host "Tip: Use -Mode SafeClean for safe cleaning" -ForegroundColor Gray
                Write-Host "Tip: Use -Mode DeepClean for deep cleaning" -ForegroundColor Gray
                Write-Host "Tip: Use -Mode Migrate -TargetDrive D for directory migration" -ForegroundColor Gray
                Write-Host "Tip: Use -Mode ResidueScan to find uninstall leftovers" -ForegroundColor Gray
                Write-Host "Tip: Add -WhatIf to preview any action" -ForegroundColor Gray
            }
            "SafeClean" {
                if ($CleanReq -and $CleanReq.paths) {
                    Invoke-SafeClean -items $results -OnlyPaths @($CleanReq.paths) -NonInteractive
                } else {
                    Invoke-SafeClean -items $results
                }
            }
            "DeepClean" {
                if ($CleanReq -and $CleanReq.paths) {
                    Invoke-DeepClean -items $results -OnlyPaths @($CleanReq.paths) -NonInteractive
                } else {
                    Invoke-DeepClean -items $results
                }
            }
            "Migrate" {
                Start-DirMigration -items $results -targetDrive $TargetDrive
            }
        }
    }

    # Export report
    if ($ExportReport) {
        Export-Report -items $results -reportPath $ExportReport
    }

    # Export JSON (for web frontend)
    if ($ExportJson) {
        if ($Mode -eq "Scan") {
            Export-ResultJson -items $results -path $ExportJson
        } else {
            $obj = [PSCustomObject]@{
                timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                type = "clean"
                mode = $Mode
                stats = [PSCustomObject]@{ cleaned = $Stats.Cleaned; skipped = $Stats.Skipped; migrated = $Stats.Migrated }
            }
            $obj | ConvertTo-Json -Depth 5 | Set-Content $ExportJson -Encoding UTF8
        }
    }

    # Final stats
    Write-Host ""
    Write-Host "===== Done =====" -ForegroundColor Cyan
    $finalMsg = "  Cleaned: {0} | Migrated: {1} | Skipped: {2}" -f $Stats.Cleaned, $Stats.Migrated, $Stats.Skipped
    Write-Host $finalMsg -ForegroundColor White

    if ($Stats.Cleaned -gt 0) {
        Write-Host ("  Backups stored at: {0}" -f $BackupDir) -ForegroundColor Gray
        Write-Host "  Use -Mode Restore to recover items" -ForegroundColor Gray
    }
    Write-Host ("  Log file: {0}" -f $LogFile) -ForegroundColor Gray

    if (Test-Path $UnknownRegistry) {
        try {
            $regData = Get-Content $UnknownRegistry -Raw -Encoding UTF8 | ConvertFrom-Json
            Write-Host ("  Unknown apps discovered: {0} (saved to registry)" -f $regData.Count) -ForegroundColor Gray
        } catch { }
    }
}

# ============================================================
# Entry (dot-source 时（如 web_server.ps1）不自动执行)
# ============================================================
if ($MyInvocation.InvocationName -ne '.') {
    Main
}
