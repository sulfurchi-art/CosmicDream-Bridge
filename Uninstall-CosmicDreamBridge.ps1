[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'CosmicDream\Bridge'),

    [string]$TaskName = 'Cosmic Dream Bridge'
)

$ErrorActionPreference = 'Stop'
$productId = 'CosmicDreamBridge'

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
$markerPath = Join-Path $resolvedInstallRoot '.cosmic-dream-bridge.json'
$bridgePath = Join-Path $resolvedInstallRoot 'CosmicDreamBridge.ps1'

function Stop-InstalledBridge {
    param([string]$ScriptPath)

    $normalized = [System.IO.Path]::GetFullPath($ScriptPath)
    try {
        Get-CimInstance Win32_Process |
            Where-Object {
                $_.ProcessId -ne $PID -and
                $_.Name -match '^(?:powershell|pwsh)(?:\.exe)?$' -and
                $_.CommandLine -and
                $_.CommandLine.IndexOf($normalized, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
            } |
            ForEach-Object {
                [void](Invoke-CimMethod -InputObject $_ -MethodName Terminate)
            }
    } catch {}
}

function Remove-BridgeTask {
    param(
        [string]$Name,
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
    $owned = (
        $description -eq 'Starts Cosmic Dream Bridge for the current user.' -and
        $action -and
        ([string]$action.Arguments).IndexOf(
            $normalizedScript,
            [System.StringComparison]::OrdinalIgnoreCase
        ) -ge 0
    )
    if (-not $owned) {
        throw "Refusing to remove a scheduled task not owned by Cosmic Dream Bridge: $Name"
    }
    $folder.DeleteTask($Name, 0)
}

if (-not (Test-Path -LiteralPath $resolvedInstallRoot)) {
    Write-Host 'Cosmic Dream Bridge is not installed.'
    return
}
if (-not (Test-Path -LiteralPath $markerPath)) {
    throw "Refusing to remove an unmarked directory: $resolvedInstallRoot"
}

$marker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
if ($marker.product -ne $productId) {
    throw "Refusing to remove a directory owned by another product: $resolvedInstallRoot"
}

if ($PSCmdlet.ShouldProcess($resolvedInstallRoot, 'Uninstall Cosmic Dream Bridge')) {
    Stop-InstalledBridge -ScriptPath $bridgePath
    Remove-BridgeTask -Name $TaskName -ScriptPath $bridgePath
    Start-Sleep -Milliseconds 150
    [void](Get-SafeInstallRoot -Path $resolvedInstallRoot)
    Remove-Item -LiteralPath $resolvedInstallRoot -Recurse -Force
    Write-Host 'Cosmic Dream Bridge uninstalled.'
}
