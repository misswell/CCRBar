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
- 检测 Gateway (默认 `127.0.0.1:3456`) 和 Management (默认 `127.0.0.1:3458`)
- 启动 / 停止 / 重启 CCR
- 打开 CCR Dashboard（`ccr ui`）
- 打开 CCR 数据目录（`~/.claude-code-router`）
- 登录启动（SMAppService）
- 自动启动 CCR（默认开启；App 启动时，仅当 CCR 未完全运行）
- 在线更新（启动时自动检查，每天一次，也可手动检查）
- 自动识别桌面版 `ccr-app` 自带的 Node.js，或从本机已安装版本中选择 Node.js 22+
- 修改 CCR Management 端口（默认 `3458`，提交后自动重启 CCR）

## 最新发布

- `v0.1.8`：修复 Stop 点击后服务已停止但菜单状态不刷新、以及自动启动竞态问题；修复桌面版运行时误报未安装。
- `v0.1.5`：菜单显示产品名和版本；`Start CCR` 与 `Stop CCR` 按当前状态互斥。
- `v0.1.4`：替换为 A2 IP 图标，更新 macOS 应用视觉资源。

### 自动识别与端口

启动时会优先检测官方 `ccr` CLI；如果没有，则检测 Claude Code Router 桌面版提供的
`~/.claude-code-router/bin/ccr-app`。桌面版使用 Electron 自带的 Node.js，不依赖系统 Node.js。
普通 CLI 模式会扫描 PATH、nvm、fnm、asdf、mise、Volta 等常见安装位置，选择最高的 Node.js 22+
版本，仅为 CCR 进程临时调整 PATH，不会修改用户的 shell 配置。

菜单栏里的 `Management Port` 对应 CCR 的管理服务端口（CLI 的 `--port` 参数），默认是 `3458`。
Gateway 端口仍由 CCR 自身配置管理，默认是 `3456`。

## 构建

```bash
xcodegen generate
xcodebuild -project CCRBar.xcodeproj -scheme CCRBar -configuration Release build
```

产物：`build/Release/CCRBar.app`（或 DerivedData 对应目录）

在线更新的发布流程见 [docs/UPDATES.md](docs/UPDATES.md)。

## 项目结构

```
CCRBar/
├── App/
│   ├── CCRBarApp.swift
│   └── AppState.swift
├── Models/
│   ├── AppSettings.swift
│   └── CCRStatus.swift
├── Services/
│   ├── CCRExecutableResolver.swift
│   ├── CCRServiceManager.swift
│   ├── CCRStatusMonitor.swift
│   ├── CommandRunner.swift
│   ├── LoginItemManager.swift
│   └── UpdateManager.swift
├── Views/
│   ├── MenuBarView.swift
│   ├── StatusView.swift
│   └── SettingsView.swift
├── Resources/
│   ├── CCRBar.entitlements
│   └── Info.plist
└── Utilities/
    └── Version.swift
```

`CCRBar/Resources/Info.plist` contains the Sparkle update feed and public signing key.
