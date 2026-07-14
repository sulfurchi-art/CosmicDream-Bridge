# Cosmic Dream Bridge

Cosmic Dream Bridge is the optional Windows companion for the Wallpaper Engine
edition of Cosmic Dream. It supplies system-wide CPU, GPU, memory and network
metrics to W02 and supplies the current Windows media session metadata,
playback state and timeline to W03. It also sends the previous, play/pause and
next media keys, seeks the active session when the W03 progress rail is dragged,
and aligns W02 with Task Manager semantics: processor utility for CPU,
available physical memory, the busiest GPU engine, and the busiest active
network adapter in Mbps. Audio spectrum data remains entirely inside Wallpaper
Engine. The bridge also supplies the native W01 task editor used when desktop
keyboard focus is unavailable.

Current release: `1.4.0`.

## Install

Open PowerShell or CMD, paste this command, and press Enter:

```cmd
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$p=Join-Path $env:TEMP 'Install-CosmicDreamBridge-Standalone.ps1'; $expected='E2C37D8B2D90BB9630E1FD5D915D0E0BF66CBED16C59D4E7A0804EA087876B2D'; $sources=@('https://gitcode.com/gcw_iBQYxQC8/CosmicDream-Bridge/releases/download/v1.4.0/Install-CosmicDreamBridge-Standalone.ps1','https://github.com/sulfurchi-art/CosmicDream-Bridge/releases/download/v1.4.0/Install-CosmicDreamBridge-Standalone.ps1'); $ok=$false; foreach($u in $sources){try{Invoke-WebRequest -UseBasicParsing $u -OutFile $p; if((Get-FileHash -Algorithm SHA256 $p).Hash -eq $expected){$ok=$true; break}}catch{}; Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue}; if(-not $ok){throw 'Cosmic Dream Bridge download or SHA-256 verification failed.'}; & $p"
```

The installer tries the GitCode mirror first, falls back to GitHub, and verifies
the downloaded script with SHA-256 before execution.

Alternatively, download the standalone installer, open PowerShell in its
directory and run:

```powershell
powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\Install-CosmicDreamBridge-Standalone.ps1
```

The standalone file contains the complete runtime and uninstaller. The
multi-file `Install-CosmicDreamBridge.ps1` remains available for development and
packaged release testing.

Run the same standalone installer again to update an existing installation. It
replaces the bridge runtime and restarts the current-user background task.

Administrator rights are not required. The installer copies the runtime to
`%LOCALAPPDATA%\CosmicDream\Bridge`, registers a hidden current-user logon task
and starts the bridge immediately. Cosmic Dream discovers the fixed loopback
endpoint automatically; there is no port setting to configure.

The bridge exposes these loopback endpoints:

- `GET /v1/health`
- `GET /v1/metrics` (system metrics plus current media-session state)
- `POST /v1/media/command?command=previous|toggle|next`
- `POST /v1/media/seek?position=<seconds>`
- `POST /v1/todo/editor?<task-fields>`

Verify the installation at:

```text
http://127.0.0.1:8765/v1/health
```

## Uninstall

```powershell
& "$env:LOCALAPPDATA\CosmicDream\Bridge\Uninstall-CosmicDreamBridge.ps1"
```

The uninstaller stops the installed process, removes the current-user logon task
and deletes only a directory carrying the Cosmic Dream Bridge installation
marker.

## Development

Run the bridge directly on a test port:

```powershell
.\Start-CosmicDreamBridge.cmd -Port 18765
```

The HTTP server binds only to `127.0.0.1`. Browser access is limited to local,
file-based and Wallpaper Engine origins. Media commands additionally require the
Cosmic Dream client header and accept `POST` requests only. The task editor uses
the same authenticated local route and opens a standard Windows dialog in the
current user's desktop session.
