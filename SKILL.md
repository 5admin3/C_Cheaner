---
name: c-drive-cleaner
description: 安全高效的C盘清理工具。通用扫描引擎+80软件知识库+三级安全分级+目录联接迁移+卸载残留扫描+Web实时仪表盘。不影响任何软件运行。
metadata:
  type: skill
  version: "2.1.3"
  platform: windows
  requires_admin: true
  category: system-utility
---

# C盘清理技能 (C Drive Cleaner)

## 概述

安全的 Windows C 盘清理 PowerShell 工具。核心理念：**清理过程中不影响任何软件运行，不丢失任何用户数据**。

提供两种使用方式：
1. **命令行模式**：`C_Cleaner.ps1` 单入口模式分发
2. **Web 仪表盘**：`web_server.ps1` 启动本地服务，浏览器实时查看 C 盘情况，可视化勾选清理

## 触发条件

当用户提出以下需求时使用此 skill：
- C 盘空间不足、变红、爆满
- 想要清理磁盘垃圾/缓存/临时文件
- 需要安全地释放 C 盘空间
- 想把某些大目录迁移到其他盘
- 想知道 C 盘哪些文件占用大量空间（仅扫描）
- **想用网页实时查看 C 盘占用和清理项**
- **想清理软件卸载后残留的注册表条目/孤儿目录/失效快捷方式/AppData 数据**

## AI 执行协议

### 所有操作前必须确认

1. 脚本目录：`$PSScriptRoot` 即此 skill 所在目录
2. 必须以**管理员权限**运行 PowerShell
3. PowerShell 版本 >= 5.1，Windows 10/11 (x64)

### 命令执行模板

所有命令必须在 skill 目录下执行。`{SKILL_DIR}` = `C:\Users\qi\Desktop\C-clear`（即本 skill 所在目录，可用 `$PSScriptRoot` 取得）

**Web 仪表盘（推荐给用户展示）：**

| 用户意图 | 命令 | 说明 |
|---------|------|------|
| 启动网页仪表盘 | `powershell -NoProfile -ExecutionPolicy Bypass -File "{SKILL_DIR}\web_server.ps1" -OpenBrowser` | 浏览器打开 http://127.0.0.1:8080，实时查看 C 盘、勾选清理、扫描卸载残留、备份恢复。**建议以管理员身份运行以获得完整清理权限** |

**命令行模式：**

| 用户意图 | 命令 | 说明 |
|---------|------|------|
| 先看看有什么可清理 | `powershell -NoProfile -ExecutionPolicy Bypass -File "{SKILL_DIR}\C_Cleaner.ps1" -Mode Scan` | 纯扫描，不做任何修改 |
| 预览安全清理 | `powershell -NoProfile -ExecutionPolicy Bypass -File "{SKILL_DIR}\C_Cleaner.ps1" -WhatIf -Mode SafeClean` | 预览绿色级别 |
| 执行安全清理 | `powershell -NoProfile -ExecutionPolicy Bypass -File "{SKILL_DIR}\C_Cleaner.ps1" -Mode SafeClean` | 仅删除绿色缓存 |
| 深度清理预览 | `powershell -NoProfile -ExecutionPolicy Bypass -File "{SKILL_DIR}\C_Cleaner.ps1" -WhatIf -Mode DeepClean` | 预览绿色+黄色 |
| 执行深度清理 | `powershell -NoProfile -ExecutionPolicy Bypass -File "{SKILL_DIR}\C_Cleaner.ps1" -Mode DeepClean` | 交互式逐项确认 |
| **扫描卸载残留** | `powershell -NoProfile -ExecutionPolicy Bypass -File "{SKILL_DIR}\C_Cleaner.ps1" -Mode ResidueScan` | 扫描注册表残留条目/孤儿目录/失效快捷方式/AppData 残留 |
| **清理卸载残留** | `powershell -NoProfile -ExecutionPolicy Bypass -File "{SKILL_DIR}\C_Cleaner.ps1" -Mode ResidueClean -CleanFromJson <file>` | 按 JSON 列表清理残留 |
| 迁移目录预览 | `powershell -NoProfile -ExecutionPolicy Bypass -File "{SKILL_DIR}\C_Cleaner.ps1" -WhatIf -Mode Migrate -TargetDrive D` | 预览迁移到D盘 |
| 执行目录迁移 | `powershell -NoProfile -ExecutionPolicy Bypass -File "{SKILL_DIR}\C_Cleaner.ps1" -Mode Migrate -TargetDrive D` | 实际迁移 |
| 恢复迁移 | `powershell -NoProfile -ExecutionPolicy Bypass -File "{SKILL_DIR}\C_Cleaner.ps1" -Mode Restore` | 列出备份，选择恢复 |
| 非交互恢复单个备份 | `powershell -NoProfile -ExecutionPolicy Bypass -File "{SKILL_DIR}\C_Cleaner.ps1" -Mode Restore -RestoreBackup <name>` | 供 Web 前端调用 |
| 导出HTML报告 | `powershell -NoProfile -ExecutionPolicy Bypass -File "{SKILL_DIR}\C_Cleaner.ps1" -Mode Scan -ExportReport "{SKILL_DIR}\scan_report.html"` | 生成可视化报告 |
| 导出JSON结果 | `powershell -NoProfile -ExecutionPolicy Bypass -File "{SKILL_DIR}\C_Cleaner.ps1" -Mode Scan -ExportJson <path>` | 供 Web 前端/程序消费 |

### 安全原则（AI 必须遵守）

1. **总是先运行 Scan 模式**，向用户展示扫描结果后再执行清理
2. **对于 DeepClean 和 Migrate 模式**，始终先加 `-WhatIf` 预览
3. **绝不建议用户跳过进程检测**（`-SkipProcessCheck`），除非用户明确要求
4. **红色级别（SystemProtected）在任何模式下都不会被操作**，无须担心
5. **黄色项目**在 DeepClean 模式下会**逐个询问**，让用户决定
6. 清理前提醒用户关闭正在运行的大型软件（以获得更好的清理效果）

### Web 仪表盘使用说明（AI 应向用户这样介绍）

1. 运行 `web_server.ps1` 启动服务（建议管理员身份），浏览器打开 `http://127.0.0.1:8080`
2. 页面实时显示 C 盘容量圆环（每 5 秒自动刷新），区分：
   - **可安全清理（绿）**：缓存/临时/日志，勾选后一键清理，自动备份
   - **需确认（黄）**：聊天记录/配置/数据，前端弹窗逐项确认
   - **系统保护（红）**：只读展示，永不操作
   - **卸载残留**：注册表条目（删前自动导出 .reg）/孤儿目录/失效快捷方式/AppData 残留/Windows 更新缓存
   - **备份恢复**：列出所有备份，一键还原
3. 扫描与清理在**后台独立进程**执行，前端轮询任务状态，可随时关闭页面、任务继续
4. 服务器假死保护：主循环 30 秒看门狗 + 15 秒响应写超时 + 心跳文件 `web_state\server_heartbeat.txt`（排查问题时先看心跳时间是否在更新）
5. 服务器日志写在 `web_state\server.log`（不依赖 stdout，避免后台运行管道阻塞）

### Web API 一览

| 接口 | 方法 | 说明 |
|------|------|------|
| `/` | GET | 前端页面 |
| `/api/status` | GET | 服务器状态、是否管理员 |
| `/api/disk` | GET | 所有磁盘实时容量 |
| `/api/scan` | POST | 启动扫描任务 |
| `/api/residue` | POST | 启动卸载残留扫描任务 |
| `/api/clean` | POST | 清理任务（body: `{mode: SafeClean\|DeepClean\|ResidueClean, paths[], residues[]}`） |
| `/api/task?type=` | GET | 任务状态与结果（scan/residue/clean/restore） |
| `/api/backups` | GET | 备份列表 |
| `/api/restore` | POST | 恢复备份（body: `{name}`） |
| `/api/log` | GET | 最近 300 行运行日志 |

### 结果解读指南

扫描完成后，AI 应帮助用户理解输出：

- **绿色 (Green)** = 缓存/临时文件/日志，可安全删除，`SafeClean` 模式会自动清理
- **黄色 (Yellow)** = 聊天记录/配置/下载历史等，需用户判断，`DeepClean` 模式逐项确认
- **红色 (Red)** = 系统文件/驱动/注册表，**永远不碰**
- **大小排序**：脚本按占用空间从大到小排列，优先关注前排大文件
- **运行中软件**：检测到正在运行的软件相关文件会被自动跳过

### 典型对话流程

```
用户: "我C盘红了帮我清理"
AI: 先运行 Scan 模式→展示扫描结果→根据结果推荐模式→用户确认→执行清理→展示清理结果
```

## 核心能力

| 能力 | 说明 |
|------|------|
| 通用扫描引擎 | 遍历 C:\Users\* 所有用户目录，按大小排序 |
| 80+ 软件知识库 | 覆盖 IM(12)、办公(5)、浏览器(7)、开发(16)、设计(8)、游戏(5)、云盘(6)、AI工具(5)、媒体(6) |
| 三级安全分级 | 绿色(安全自动)/黄色(确认后删)/红色(系统保护) |
| **Web 实时仪表盘** | 本地 HttpListener 服务，浏览器实时查看磁盘占用、可清理/不可清理项，可视化勾选清理 |
| **卸载残留扫描** | 注册表卸载条目残留 / Program Files 孤儿目录 / 开始菜单失效快捷方式 / AppData 残留数据 / Windows 系统残留（更新缓存等） |
| 目录联接迁移 | robocopy 复制 + SHA256 验证 + mklink /J 联接，应用无感知 |
| 备份与恢复 | .bak 备份，一键恢复，可回退 |
| JSON 输入输出 | `-ExportJson` 结构化输出、`-CleanFromJson` 指定路径非交互清理（Web 前端依赖） |
| 多用户适配 | 自动遍历 C:\Users\* 所有账户 |
| 可扩展 | 未知软件自动注册，下次识别 |

## 文件结构

```
C_clear_skill/
├── C_Cleaner.ps1              # 核心引擎（模式分发，含残留扫描，~43KB+）
├── web_server.ps1             # Web 服务器（HttpListener，后台任务调度，看门狗+心跳）
├── web/
│   └── index.html             # 前端仪表盘（单文件，无外部依赖）
├── web_state/                 # Web 运行时状态（任务结果 JSON、心跳、日志，可随时删除）
├── software_knowledge.json    # 80+ 软件知识库 (~25KB)
├── config.json                # 用户配置文件
├── SKILL.md                   # 本文件
└── README.md                  # 人类可读说明
```

**注意**：`C_Cleaner.ps1` 与 `web_server.ps1` 必须保存为 **UTF-8 带 BOM** 编码（PowerShell 5.1 按 ANSI 解析无 BOM 文件会乱码报错）。`web\index.html` 无此要求。

## 配置项说明

`config.json` 中的关键参数（用户可能需要调整）：

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `target_drive` | D | 迁移目标盘符 |
| `min_file_age_days` | 7 | 至少7天前的文件才清理 |
| `min_size_mb` | 50 | 扫描时忽略小于50MB的目录 |
| `max_scan_depth` | 2 | 扫描深度（层数） |
| `excluded_users` | Public, Default | 跳过的用户名 |
| `auto_confirm_green` | true | 绿色级别自动确认 |
| `category_enabled` | 见配置 | 各软件类别开关 |

## 知识库覆盖

| 类别 | 数量 | 覆盖软件 |
|------|------|---------|
| 即时通讯 | 12 | 微信, QQ, 钉钉, 飞书, Slack, Telegram, Discord, Teams, Zoom, Skype |
| 浏览器 | 7 | Chrome, Edge, Firefox, Brave, Opera, Vivaldi, Arc |
| 办公协作 | 5 | Office, WPS, Notion, Evernote, OneNote |
| 开发工具 | 16 | VS Code, VS, JetBrains全系, npm, pip, Docker, Git, Android Studio, Unity, UE |
| 设计创作 | 8 | Adobe全系, Figma, Blender, AutoCAD, DaVinci Resolve |
| 游戏平台 | 5 | Steam, Epic, WeGame, 育碧, 战网 |
| 云盘同步 | 6 | 百度网盘, OneDrive, Google Drive, Dropbox, 阿里云盘, 天翼/123 |
| AI工具 | 5 | Cursor, Copilot, ChatGPT, Trae, Windsurf |
| 媒体播放 | 6 | 网易云, QQ音乐, 酷狗, Spotify, VLC, 哔哩哔哩 |
| 系统工具 | 5 | 缩略图, 临时文件, Delivery Optimization, NVIDIA驱动 |
