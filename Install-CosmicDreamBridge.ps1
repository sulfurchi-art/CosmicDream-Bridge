[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [ValidateRange(1024, 65535)]
    [int]$Port = 8765,

    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'CosmicDream\Bridge'),

    [string]$TaskName = 'Cosmic Dream Bridge',

    [switch]$NoAutoStart,

    [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'
$productId = 'CosmicDreamBridge'
$productVersion = '1.6.3'
$sourceBridge = Join-Path $PSScriptRoot 'CosmicDreamBridge.ps1'
$sourceUninstaller = Join-Path $PSScriptRoot 'Uninstall-CosmicDreamBridge.ps1'
$sourceInstaller = $MyInvocation.MyCommand.Path

function Get-SafeInstallRoot {
    param([string]$Path)

    $localAppData = [System.IO.Path]::GetFullPath(
        [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    ).TrimEnd([char[]]'\/')
    if ([string]::IsNullOrWhiteSpace($localAppData)) {
        throw 'The current user LocalAppData directory is unavailable.'
    }

    $candidate = [System.IO.Path]::GetFullPath($Path).TrimEnd([char[]]'\/')
    $localPrefix = $localAppData + [System.IO.Path]::DirectorySeparatorChar
    $productRoot = [System.IO.Path]::GetFullPath(
        (Join-Path $localAppData 'CosmicDream\Bridge')
    ).TrimEnd([char[]]'\/')
    $productPrefix = $productRoot + [System.IO.Path]::DirectorySeparatorChar
    if (
        -not $candidate.Equals($productRoot, [System.StringComparison]::OrdinalIgnoreCase) -and
        -not $candidate.StartsWith($productPrefix, [System.StringComparison]::OrdinalIgnoreCase)
    ) {
        throw "InstallRoot must be CosmicDream\\Bridge or one of its child directories: $candidate"
    }

    $relativePath = $candidate.Substring($localPrefix.Length)
    $currentPath = $localAppData
    foreach ($segment in $relativePath.Split([char[]]'\/', [System.StringSplitOptions]::RemoveEmptyEntries)) {
        $currentPath = Join-Path $currentPath $segment
        if (-not (Test-Path -LiteralPath $currentPath)) { break }
        $item = Get-Item -LiteralPath $currentPath -Force
        if (-not $item.PSIsContainer) {
            throw "InstallRoot contains a non-directory path component: $currentPath"
        }
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "InstallRoot cannot traverse a reparse point: $currentPath"
        }
    }
    return $candidate
}

$resolvedInstallRoot = Get-SafeInstallRoot -Path $InstallRoot
$bridgePath = Join-Path $resolvedInstallRoot 'CosmicDreamBridge.ps1'
$uninstallerPath = Join-Path $resolvedInstallRoot 'Uninstall-CosmicDreamBridge.ps1'
$installerPath = Join-Path $resolvedInstallRoot 'Install-CosmicDreamBridge.ps1'
$markerPath = Join-Path $resolvedInstallRoot '.cosmic-dream-bridge.json'
$settingsPath = Join-Path $resolvedInstallRoot 'bridge.json'
$logPath = Join-Path $resolvedInstallRoot 'bridge.log'
$powershellPath = Join-Path $PSHOME 'powershell.exe'

if (Test-Path -LiteralPath $resolvedInstallRoot) {
    $existingEntries = @(Get-ChildItem -LiteralPath $resolvedInstallRoot -Force)
    if ($existingEntries.Count -gt 0) {
        if (-not (Test-Path -LiteralPath $markerPath)) {
            throw "Refusing to claim a non-empty unmarked directory: $resolvedInstallRoot"
        }
        $existingMarker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
        if ($existingMarker.product -ne $productId) {
            throw "Refusing to install over a directory owned by another product: $resolvedInstallRoot"
        }
    }
}

if (-not (Test-Path -LiteralPath $powershellPath)) {
    $powershellPath = (Get-Command powershell.exe -ErrorAction Stop).Source
}
if (-not (Test-Path -LiteralPath $sourceBridge)) {
    throw "Missing companion runtime: $sourceBridge"
}
if (-not (Test-Path -LiteralPath $sourceUninstaller)) {
    throw "Missing uninstaller: $sourceUninstaller"
}
if ($TaskName.IndexOfAny([char[]]'\/') -ge 0) {
    throw 'TaskName cannot contain slash characters.'
}

function Stop-InstalledBridge {
    param(
        [string]$ScriptPath,
        [string]$Name
    )

    $normalized = [System.IO.Path]::GetFullPath($ScriptPath)
    try { Stop-ScheduledTask -TaskName $Name -ErrorAction Stop } catch {}

    $matchingProcesses = @(
        Get-CimInstance Win32_Process |
            Where-Object {
                $_.ProcessId -ne $PID -and
                $_.Name -match '^(?:powershell|pwsh)(?:\.exe)?$' -and
                $_.CommandLine -and
                $_.CommandLine.IndexOf($normalized, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
            }
    )
    foreach ($process in $matchingProcesses) {
        Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
    }

    $deadline = [datetime]::UtcNow.AddSeconds(8)
    do {
        $remaining = @(
            Get-CimInstance Win32_Process |
                Where-Object {
                    $_.ProcessId -ne $PID -and
                    $_.CommandLine -and
                    $_.CommandLine.IndexOf($normalized, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
                }
        )
        if ($remaining.Count -eq 0) { break }
        Start-Sleep -Milliseconds 200
    } while ([datetime]::UtcNow -lt $deadline)

    if ($remaining.Count -gt 0) {
        throw "Existing Cosmic Dream Bridge process did not stop: $($remaining.ProcessId -join ', ')"
    }
}

function Register-BridgeTask {
    param(
        [string]$Name,
        [string]$Executable,
        [string]$Arguments
    )

    $service = New-Object -ComObject 'Schedule.Service'
    $service.Connect()
    $folder = $service.GetFolder('\')
    $definition = $service.NewTask(0)
    $definition.RegistrationInfo.Description = 'Starts Cosmic Dream Bridge for the current user.'
    $definition.Settings.Enabled = $true
    $definition.Settings.Hidden = $true
    $definition.Settings.StartWhenAvailable = $true
    $definition.Settings.DisallowStartIfOnBatteries = $false
    $definition.Settings.StopIfGoingOnBatteries = $false
    $definition.Settings.ExecutionTimeLimit = 'PT0S'
    $definition.Settings.MultipleInstances = 3

    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $definition.Principal.UserId = $identity
    $definition.Principal.LogonType = 3
    $definition.Principal.RunLevel = 0

    $trigger = $definition.Triggers.Create(9)
    $trigger.Enabled = $true
    $trigger.UserId = $identity

    $action = $definition.Actions.Create(0)
    $action.Path = $Executable
    $action.Arguments = $Arguments
    $action.WorkingDirectory = Split-Path -Parent $bridgePath

    [void]$folder.RegisterTaskDefinition($Name, $definition, 6, $null, $null, 3, $null)
}

function Assert-BridgeTaskOwnership {
    param(
        [string]$Name,
        [string]$Executable,
        [string]$ScriptPath
    )

    $service = New-Object -ComObject 'Schedule.Service'
    $service.Connect()
    $folder = $service.GetFolder('\')
    try {
        $task = $folder.GetTask("\$Name")
    } catch {
        if ($_.Exception.HResult -eq -2147024894) { return }
        throw
    }
    $definition = $task.Definition
    $description = [string]$definition.RegistrationInfo.Description
    $action = if ($definition.Actions.Count -eq 1) { $definition.Actions.Item(1) } else { $null }
    $normalizedScript = [System.IO.Path]::GetFullPath($ScriptPath)
    $normalizedExecutable = [System.IO.Path]::GetFullPath($Executable)
    $owned = (
        $description -eq 'Starts Cosmic Dream Bridge for the current user.' -and
        $action -and
        [System.IO.Path]::GetFullPath([string]$action.Path).Equals(
            $normalizedExecutable,
            [System.StringComparison]::OrdinalIgnoreCase
        ) -and
        ([string]$action.Arguments).IndexOf(
            $normalizedScript,
            [System.StringComparison]::OrdinalIgnoreCase
        ) -ge 0
    )
    if (-not $owned) {
        throw "Refusing to overwrite a scheduled task not owned by Cosmic Dream Bridge: $Name"
    }
}

$launchArguments = '-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Port {1} -LogPath "{2}"' -f $bridgePath, $Port, $logPath

if (-not $NoAutoStart) {
    Assert-BridgeTaskOwnership -Name $TaskName -Executable $powershellPath -ScriptPath $bridgePath
}

if ($PSCmdlet.ShouldProcess($resolvedInstallRoot, 'Install Cosmic Dream Bridge')) {
    [void](New-Item -ItemType Directory -Path $resolvedInstallRoot -Force)
    [void](Get-SafeInstallRoot -Path $resolvedInstallRoot)
    Stop-InstalledBridge -ScriptPath $bridgePath -Name $TaskName

    Copy-Item -LiteralPath $sourceBridge -Destination $bridgePath -Force
    Copy-Item -LiteralPath $sourceUninstaller -Destination $uninstallerPath -Force
    if ($sourceInstaller) {
        Copy-Item -LiteralPath $sourceInstaller -Destination $installerPath -Force
    }
    Get-ChildItem -LiteralPath $resolvedInstallRoot -Filter '*.ps1' | Unblock-File -ErrorAction SilentlyContinue

    [ordered]@{
        product = $productId
        version = $productVersion
        installedAt = [datetime]::UtcNow.ToString('o')
    } | ConvertTo-Json | Set-Content -LiteralPath $markerPath -Encoding UTF8

    [ordered]@{
        port = $Port
        taskName = $TaskName
        installRoot = $resolvedInstallRoot
    } | ConvertTo-Json | Set-Content -LiteralPath $settingsPath -Encoding UTF8

    if (-not $NoAutoStart) {
        Register-BridgeTask -Name $TaskName -Executable $powershellPath -Arguments $launchArguments
    }

    if (-not $NoLaunch) {
        Start-Process -FilePath $powershellPath -ArgumentList $launchArguments -WindowStyle Hidden
    }

    Write-Host 'Cosmic Dream Bridge installed.'
    Write-Host "Location: $resolvedInstallRoot"
    Write-Host "Endpoint: http://127.0.0.1:$Port/v1/health"
    if ($NoAutoStart) {
        Write-Host 'Login auto-start was skipped.'
    } else {
        Write-Host "Auto-start task: $TaskName"
    }
}
