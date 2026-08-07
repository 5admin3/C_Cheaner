# C盘安全清理工具 (C_Cleaner)

## 核心理念

**清理过程中不中断任何软件运行，不丢失任何用户数据。**

## 架构概览

```
C_Cleaner.ps1                 ← 核心引擎（单一入口，模式分发）
├── 通用扫描引擎              ← 遍历 C:\Users\* 所有用户目录，按大小排序
├── 软件知识库引擎            ← 加载/匹配 80 个软件缓存路径
├── 安全分级引擎              ← 三级分级 + 运行中进程保护
├── 安全清理引擎              ← 按级别清理 + .bak 备份
├── 目录联接迁移引擎          ← robocopy + mklink /J，应用无感知
├── 备份与恢复模块            ← .bak 打包 + 一键恢复
├── 进程检测模块              ← 检测运行中程序，跳过其文件
├── 卸载残留扫描引擎          ← 注册表条目/孤儿目录/失效快捷方式/AppData 残留
├── JSON 输入输出             ← -ExportJson 输出 / -CleanFromJson 非交互清理
├── 多用户适配                ← 自动识别 C:\Users\* 所有账户
└── 扩展性模块                ← 未知软件自动注册

web_server.ps1                ← Web 服务器（HttpListener + 后台任务调度）
└── web/index.html            ← 前端仪表盘（实时磁盘/清理/残留/备份/日志）
```

## 文件说明

| 文件 | 用途 |
|------|------|
| `C_Cleaner.ps1` | 核心 PowerShell 脚本（UTF-8 BOM 编码） |
| `web_server.ps1` | Web 服务器（UTF-8 BOM 编码） |
| `web/index.html` | Web 前端仪表盘（单文件，无外部依赖） |
| `web_state/` | Web 运行时状态（任务结果/心跳/日志，可删） |
| `software_knowledge.json` | 80 个软件条目知识库 |
| `config.json` | 用户配置文件 |
| `unknown_software_registry.json` | 未知软件自动注册表（运行时生成，可删） |
| `README.md` | 本说明文档 |

## 快速开始

### 1. 基础要求

- Windows 10/11 (x64)
- PowerShell 5.1+
- **管理员权限**（清理/迁移/注册表操作需要；Web 扫描查看无需）

### 2. Web 仪表盘（推荐）

```powershell
# 以管理员身份运行 PowerShell，进入 skill 目录
cd C:\Users\qi\Desktop\C-clear
.\web_server.ps1 -OpenBrowser
```

浏览器自动打开 `http://127.0.0.1:8080`，即可：
- 实时查看 C 盘容量（每 5 秒刷新）
- 扫描并查看可清理（绿）/需确认（黄）/系统保护（红）项目
- 扫描卸载残留（注册表条目/孤儿目录/失效快捷方式/AppData 残留/Windows 更新缓存）
- 勾选清理（删除前自动备份）+ 备份恢复 + 运行日志

### 3. 首次命令行运行 — 先预览

```powershell
# 右键 PowerShell → 以管理员身份运行
cd C:\Users\qi\Desktop\C-clear
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass

# 预览模式扫描（看看会处理什么，不执行任何操作）
.\C_Cleaner.ps1 -WhatIf -Mode Scan
```

### 3. 安全清理（推荐首选）

```powershell
# 仅清理绿色（安全）级别，自动执行
.\C_Cleaner.ps1 -Mode SafeClean
```

### 4. 深度清理

```powershell
# 包含黄色（需确认）项，逐项询问
.\C_Cleaner.ps1 -Mode DeepClean
```

### 5. 目录迁移

```powershell
# 先预览
.\C_Cleaner.ps1 -Mode Migrate -TargetDrive D -WhatIf

# 确认后执行
.\C_Cleaner.ps1 -Mode Migrate -TargetDrive D
```

### 6. 扫描卸载残留（v2.1 新增）

```powershell
# 扫描软件卸载后遗留的"尸体"
.\C_Cleaner.ps1 -Mode ResidueScan

# 按 JSON 列表清理残留（Web 前端自动调用，也可手工构造）
.\C_Cleaner.ps1 -Mode ResidueClean -CleanFromJson web_state\clean_request.json
```

残留扫描覆盖 5 类：
1. **注册表卸载条目残留**（黄）—— 卸载条目指向的目录已不存在，删前自动导出 .reg 备份
2. **Program Files 孤儿目录**（黄）—— 目录存在但注册表无对应软件，需人工确认
3. **开始菜单失效快捷方式**（绿）—— 快捷方式指向的目标已不存在，直接删
4. **AppData 残留数据**（黄）—— 软件已卸载但数据目录仍在（超过 90 天未更新才报告）
5. **Windows 系统残留**（绿）—— 更新缓存（SoftwareDistribution）、Prefetch、系统 Temp

### 7. 一键恢复

```powershell
# 列出所有备份，选择恢复
.\C_Cleaner.ps1 -Mode Restore
```

## 参数一览

| 参数 | 说明 | 可选值 |
|------|------|--------|
| `-Mode` | 运行模式 | `Scan`(默认), `SafeClean`, `DeepClean`, `Migrate`, `Restore`, `ResidueScan`, `ResidueClean` |
| `-WhatIf` | 预览模式 | 开关 |
| `-TargetDrive` | 迁移目标盘 | 盘符字母, 默认 `D` |
| `-ExportReport` | 导出HTML报告 | 文件路径 |
| `-ExportJson` | 导出JSON结果（供Web前端） | 文件路径 |
| `-CleanFromJson` | 从JSON读取清理列表（非交互，Web前端用） | 文件路径 |
| `-RestoreBackup` | 非交互恢复单个备份（Web前端用） | 备份文件名 |
| `-NoBanner` | 隐藏启动横幅（后台进程用） | 开关 |
| `-ConfigPath` | 自定义配置路径 | 文件路径 |
| `-SkipProcessCheck` | 跳过进程检测 | 开关 |

## 三级安全分级说明

### 绿色 — SafeClean（自动清理）
- 浏览器缓存（Chrome/Edge/Firefox 等）
- IDE 缓存/日志（VS Code/VS/JetBrains）
- 设计软件缓存（Adobe/Figma/Blender）
- 游戏平台缓存（Steam/Epic）
- Windows 临时文件/缩略图缓存
- 各软件已知日志和临时文件

### 黄色 — ConfirmRequired（需确认）
- IM 聊天记录/文件/图片（微信/QQ/钉钉/飞书）
- 办公软件备份/历史（WPS/Office）
- 云盘同步缓存（百度网盘等）
- AppData 下未知软件数据
- 用户文档/下载目录

### 红色 — SystemProtected（绝不触碰）
- `C:\Windows\System32` 等系统目录
- `C:\Program Files` 程序安装目录
- 正在运行的软件相关目录
- 系统驱动和注册表

## 目录联接迁移原理

```
迁移前:  C:\Users\X\AppData\LargeCache  (20GB, 占用C盘)
                ↓
迁移中:  robocopy → D:\C_Cleaner_Migrated\Users\X\AppData\LargeCache
         抽样SHA256校验通过
         C:\...\LargeCache → 重命名为 LargeCache.bak (安全备份)
                ↓
迁移后:  mklink /J C:\...\LargeCache → D:\...\LargeCache
         应用程序访问原路径 → 自动转到D盘 → 完全无感知
         确认正常后手动删除 .bak
```

**回退**: 删除联接 → 重命名 .bak 恢复原目录 → 删除目标盘副本

## 软件知识库覆盖

| 类别 | 数量 | 代表软件 |
|------|------|----------|
| 即时通讯 | 12 | 微信, QQ, 钉钉, 飞书, Slack, Telegram, Discord, Teams, Zoom, Skype |
| 浏览器 | 7 | Chrome, Edge, Firefox, Brave, Opera, Vivaldi, Arc |
| 办公协作 | 5 | Office, WPS, Notion, Evernote, OneNote |
| 开发工具 | 16 | VS Code, VS, JetBrains全家桶, npm, pip, Docker, Git, Android Studio, Unity, UE |
| 设计创作 | 8 | Adobe全家桶, Figma, Blender, AutoCAD, DaVinci Resolve |
| 游戏平台 | 5 | Steam, Epic, WeGame, 米哈游, 战网 |
| 云盘同步 | 6 | 百度网盘, OneDrive, Google Drive, Dropbox, 阿里云盘, 夸克/123 |
| AI工具 | 5 | Cursor, Copilot, ChatGPT, Trae, Windsurf |
| 媒体播放 | 6 | 网易云, QQ音乐, 酷狗, Spotify, VLC, Bilibili |
| 系统缓存 | 5 | 缩略图, 临时文件, Delivery Optimization, NVIDIA缓存 |

## 配置说明 (`config.json`)

```json
{
  "target_drive": "D",              // 迁移目标盘
  "min_file_age_days": 7,           // 最小文件年龄（天）
  "min_size_mb": 50,                // 最小扫描大小（MB）
  "max_scan_depth": 2,              // 最大扫描深度
  "excluded_paths": [],             // 排除路径
  "excluded_users": ["Public", "Default"],  // 排除用户
  "auto_confirm_green": true,       // 绿色项自动确认
  "preserve_junction_backup": true, // 保留迁移备份
  "robocopy_retry": 3,              // robocopy 重试次数
  "sample_verification_count": 20,  // 迁移后抽样校验数量
  "scan_downloads": true,           // 扫描下载目录
  "scan_system_temp": true,         // 扫描系统临时文件
  "log_retention_days": 30,         // 日志保留天数
  "backup_retention_days": 90,      // 备份保留天数
  "category_enabled": { "im": true, "browser": true, ... }  // 各软件类别开关
}
```

## 扩展性

遇到未知软件时自动记录到 `unknown_software_registry.json`，包含：
- 软件目录名称
- 检测日期
- 命中次数
- 建议安全级别

用户可以手动编辑该文件，将确认安全的项目标记为 `green`，下次扫描自动识别。

## 更新日志

### v2.1.3 (2026-08-07) — 安全性与容错修复

- **junction 保护**：`Remove-DirTolerant` 对顶层 junction/符号链接只跳过不清理（修复前会删除链接目标全部内容）；扫描对 reparse point 一律降级为黄色需确认
- **WhatIf 契约**：`-WhatIf -NonInteractive` 组合不再真实删除；Restore / ResidueClean 模式补齐 WhatIf 预览守卫
- **迁移可靠性**：mklink 失败现在会校验并回滚改名，不再误报成功
- **注册表残留**：reg 备份失败时中止删除该项（避免无备份不可恢复）
- **枚举防穿越**：备份改用 `Get-FilesNoReparse` 手动递归（PS 5.1 `Get-ChildItem -Recurse` 会穿越 junction）
- **残留误判修复**：`Test-IsLockedByProcess` 判断方向纠正，Windows 更新缓存等系统残留不再被误判"使用中"
- **备份保留期生效**：`backup_retention_days`（默认 90 天）自动清理过期备份，backups 不再无上限增长
- **统计诚实化**：删除全部被锁/无权限时如实报 Skipped，不再虚报"已清理"；空目录不再误报失败

### v2.1.1 (2026-08-07) — 容错修复

- 备份弃用 `Compress-Archive`（PS 5.1 遇锁定文件整体崩溃），改手动 ZipArchive 逐文件打包，锁定文件跳过
- 删除改 `Remove-DirTolerant` 逐项 .NET 删除，单文件锁定不再导致整个清理失败回滚
- 扫描 0 项时仍导出 JSON，Web 端不再误报"任务失败"

### v2.1.0 (2026-08-06) — 卸载残留扫描

- 新增残留扫描 5 类：注册表条目/孤儿目录/失效快捷方式/AppData 残留/Windows 更新缓存
- 全新 Web 仪表盘界面

## 故障排除

| 问题 | 解决方法 |
|------|----------|
| 执行策略限制 | `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass` |
| 权限不足 | 右键 PowerShell → "以管理员身份运行" |
| robocopy 失败 | 检查目标盘可用空间，检查磁盘错误 `chkdsk D: /f` |
| 联接创建失败 | 确认目标盘为 NTFS 格式 |
| 迁移后软件异常 | 使用 `-Mode Restore` 一键恢复 |
| 误删文件 | 检查 `backups\` 目录，使用 Restore 恢复 |
| 备份目录占用 C 盘空间 | 备份按 `backup_retention_days`（默认 90 天）自动清理；确认软件正常后可在 `backups\` 手动删除旧备份 |

## 安全承诺

1. **不碰系统文件**: 红色系统保护目录绝对不操作
2. **不中断运行软件**: 自动检测进程并跳过相关文件
3. **可回退**: 所有删除操作先创建 .bak 备份
4. **可预览**: `-WhatIf` 先看再删
5. **透明日志**: 所有操作写入 `C_Cleaner.log`
