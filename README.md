# CCRBar

macOS 原生 SwiftUI 菜单栏控制器，用于管理 Claude Code Router（CCR）官方 CLI。

## 设计原则

- 不使用 Electron / Tauri / Chromium / WKWebView
- 不重写 Claude Code Router，只做启停 + 状态监控 + 快捷入口
- CCR 官方 CLI 是唯一的核心逻辑来源

## 环境要求

- macOS 14+
- Node.js >= 22
- `@musistudio/claude-code-router` 全局安装

```bash
npm install -g @musistudio/claude-code-router
```

## 功能

- 菜单栏状态指示（Running / Stopped / Starting / Error）
- 检测 Gateway (127.0.0.1:3456) 和 Management (127.0.0.1:3458)
- 启动 / 停止 / 重启 CCR
- 打开 CCR Dashboard（`ccr ui`）
- 打开 CCR 数据目录（`~/.claude-code-router`）
- 登录启动（SMAppService）
- 自动启动 CCR（App 启动时，仅当 CCR 未运行）

## 构建

```bash
xcodegen generate
xcodebuild -project CCRBar.xcodeproj -scheme CCRBar -configuration Release build
```

产物：`build/Release/CCRBar.app`（或 DerivedData 对应目录）

## 项目结构

```
CCRBar/
├── App/
│   ├── CCRBarApp.swift
│   └── AppState.swift
├── Models/
│   └── CCRStatus.swift
├── Services/
│   ├── CCRExecutableResolver.swift
│   ├── CCRServiceManager.swift
│   ├── CCRStatusMonitor.swift
│   ├── CommandRunner.swift
│   └── LoginItemManager.swift
├── Views/
│   ├── MenuBarView.swift
│   ├── StatusView.swift
│   └── SettingsView.swift
└── Utilities/
    └── Version.swift
```
