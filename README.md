# Cosmic Dream Bridge

Optional Windows companion for the **Cosmic Dream** Wallpaper Engine wallpaper.

Cosmic Dream Bridge supplies system-wide CPU, GPU, memory and network metrics
to W02. It also connects W03 to Windows media controls and enables W01's native
task editor when Wallpaper Engine cannot provide desktop keyboard input.

Cosmic Dream Bridge 是 **Cosmic Dream** Wallpaper Engine 壁纸的可选 Windows
组件，为 W02 提供 CPU、GPU、内存和网络监视数据，并为 W03 与 W01 提供系统媒体控制、
进度跳转和原生任务编辑窗口。

## Install / 安装

Open PowerShell or CMD, paste this command, and press Enter:

打开 PowerShell 或 CMD，粘贴以下命令并按回车：

```cmd
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$p=Join-Path $env:TEMP 'Install-CosmicDreamBridge-Standalone.ps1'; Invoke-WebRequest -UseBasicParsing 'https://github.com/sulfurchi-art/CosmicDream-Bridge/releases/latest/download/Install-CosmicDreamBridge-Standalone.ps1' -OutFile $p; & $p"
```

Administrator rights are not required. The installer:

- installs to `%LOCALAPPDATA%\CosmicDream\Bridge`;
- registers a hidden current-user logon task;
- starts the bridge immediately;
- binds only to `127.0.0.1:8765`.

无需管理员权限。安装器会将 Bridge 安装到
`%LOCALAPPDATA%\CosmicDream\Bridge`，注册当前用户登录启动任务并立即运行。
服务仅监听本机 `127.0.0.1:8765`。

Running the same command again updates the existing installation.

再次运行同一条命令即可更新。

## Uninstall / 卸载

```powershell
& "$env:LOCALAPPDATA\CosmicDream\Bridge\Uninstall-CosmicDreamBridge.ps1"
```

## Local API

- `GET /v1/health`
- `GET /v1/metrics`
- `POST /v1/media/command?command=previous|toggle|next`
- `POST /v1/media/seek?position=<seconds>`
- `POST /v1/todo/editor`

The API only accepts local, file-based and Wallpaper Engine origins. Media and
editor actions additionally require the Cosmic Dream client header.
