# Cosmic Dream Bridge

Cosmic Dream Bridge is the optional Windows companion for the Wallpaper Engine
edition of Cosmic Dream. It supplies system-wide CPU, GPU, memory and network
metrics to W02 and supplies the current Windows media session metadata,
playback state and default output-device identity to W03. W03 is intentionally
read-only: transport commands, timeline polling and seek control were removed
to keep media integration predictable across players. The bridge also aligns
W02 with Task Manager semantics: processor utility for CPU,
available physical memory, the busiest GPU engine, and the busiest active
network adapter in Mbps. Audio spectrum data remains entirely inside Wallpaper
Engine. The bridge also supplies the native W01 task editor used when desktop
keyboard focus is unavailable.

Required runtime for this wallpaper build: `1.6.0` or newer (protocol v2).

Current maintenance candidate: `1.6.3`. It reports the current Windows
default audio output endpoint so W03 can identify the device carrying playback.
It does not replace Wallpaper Engine's official audio capture path. The release
also retains automatic GPU counter recovery, reliable in-place upgrades, real
CPU/GPU identity, and multi-GPU selection for W02.

The former `1.4.0` public installer is not compatible with this build's split
W02/W03 polling or opaque-origin authorization rules. Do not publish a one-line
Use the generated standalone asset and its matching SHA-256 from the same
release. Do not reuse a checksum from an older Bridge version.

## Install

From the verified release package, open PowerShell in the standalone installer's
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

Protocol v2 exposes these loopback endpoints. The route prefix remains `/v1`
for compatibility; `/v1/health` reports `protocolVersion: 2` and advertises the
split hardware and media endpoints.

- `GET /v1/health`
- `GET /v1/hardware` (CPU identity, per-GPU identity and usage, memory and network snapshot)
- `GET /v1/media` (current media-session metadata, playback state and output device)
- `GET /v1/metrics` (compatibility response combining hardware and media)
- `POST /v1/todo/editor?<task-fields>`
- `GET /v1/diagnostics`

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

The HTTP server binds only to `127.0.0.1`. Requests without an `Origin` header
remain available to local native clients, and `http://localhost` plus
`http://127.0.0.1` origins are allowed. `Origin: null` and `file:` origins are
accepted only when the request's live TCP connection belongs to Wallpaper
Engine's 32-bit or 64-bit wallpaper/webwallpaper process. The task editor uses
the authenticated local route and opens a standard Windows dialog in the
current user's desktop session.
