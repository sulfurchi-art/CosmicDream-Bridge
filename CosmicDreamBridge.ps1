[CmdletBinding()]
param(
    [ValidateRange(1024, 65535)]
    [int]$Port = 8765,

    [string]$LogPath = ''
)

$ErrorActionPreference = 'Stop'
$bridgeName = 'Cosmic Dream Bridge'
$bridgeVersion = '1.6.3'
$startedAt = [datetime]::UtcNow
$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
$hardwareCache = $null
$hardwareCacheTimestamp = [datetime]::MinValue
$hardwareSampleId = 0L
$hardwareCacheLifetimeMilliseconds = 50
$hardwareSampler = $null
$hardwareSamplerMode = 'LEGACY CIM'
$hardwareSamplerLastDurationMilliseconds = $null
$hardwareSamplerLastError = $null
$gpuSamplerConsecutiveFailures = 0
$gpuSamplerResetThreshold = 3
$hardwareIdentity = $null
$mediaCache = $null
$mediaCacheTimestamp = [datetime]::MinValue
$mediaSampleId = 0L
$audioOutputCache = $null
$audioOutputCacheTimestamp = [datetime]::MinValue
$audioOutputCacheLifetimeMilliseconds = 750
$verifiedWallpaperProcessIds = [System.Collections.Generic.HashSet[int]]::new()
$mutex = $null
$ownsMutex = $false
$mediaManager = $null
$mediaManagerType = $null
$mediaAsTaskMethod = $null

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class CosmicDreamTcpOwner {
    private const int AfInet = 2;
    private const int TcpTableOwnerPidAll = 5;
    private const uint ErrorInsufficientBuffer = 122;
    private const uint TcpStateEstablished = 5;

    [StructLayout(LayoutKind.Sequential)]
    private struct TcpRowOwnerPid {
        public uint State;
        public uint LocalAddress;
        public uint LocalPort;
        public uint RemoteAddress;
        public uint RemotePort;
        public uint OwningPid;
    }

    [DllImport("iphlpapi.dll", SetLastError = true)]
    private static extern uint GetExtendedTcpTable(
        IntPtr table,
        ref int size,
        bool sort,
        int addressFamily,
        int tableClass,
        uint reserved
    );

    private static int DecodePort(uint encodedPort) {
        byte[] bytes = BitConverter.GetBytes(encodedPort);
        return (bytes[0] << 8) | bytes[1];
    }

    public static int FindEstablishedOwner(int localPort, int remotePort) {
        int size = 0;
        uint status = GetExtendedTcpTable(
            IntPtr.Zero,
            ref size,
            false,
            AfInet,
            TcpTableOwnerPidAll,
            0
        );
        if (status != ErrorInsufficientBuffer || size <= 0) return 0;

        IntPtr buffer = Marshal.AllocHGlobal(size);
        try {
            status = GetExtendedTcpTable(
                buffer,
                ref size,
                false,
                AfInet,
                TcpTableOwnerPidAll,
                0
            );
            if (status != 0) return 0;

            int count = Marshal.ReadInt32(buffer);
            int rowSize = Marshal.SizeOf(typeof(TcpRowOwnerPid));
            IntPtr rowPointer = IntPtr.Add(buffer, sizeof(uint));
            for (int index = 0; index < count; index++) {
                TcpRowOwnerPid row = (TcpRowOwnerPid)Marshal.PtrToStructure(
                    IntPtr.Add(rowPointer, index * rowSize),
                    typeof(TcpRowOwnerPid)
                );
                if (
                    row.State == TcpStateEstablished &&
                    DecodePort(row.LocalPort) == localPort &&
                    DecodePort(row.RemotePort) == remotePort
                ) {
                    return unchecked((int)row.OwningPid);
                }
            }
            return 0;
        } finally {
            Marshal.FreeHGlobal(buffer);
        }
    }
}

public sealed class CosmicDreamGpuAdapterInfo {
    public int Index { get; set; }
    public string Id { get; set; }
    public string Name { get; set; }
    public uint VendorId { get; set; }
    public uint DeviceId { get; set; }
    public bool Software { get; set; }
}

public static class CosmicDreamDxgiAdapters {
    [StructLayout(LayoutKind.Sequential)]
    private struct Luid {
        public uint LowPart;
        public int HighPart;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct AdapterDesc1 {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string Description;
        public uint VendorId;
        public uint DeviceId;
        public uint SubSysId;
        public uint Revision;
        public UIntPtr DedicatedVideoMemory;
        public UIntPtr DedicatedSystemMemory;
        public UIntPtr SharedSystemMemory;
        public Luid AdapterLuid;
        public uint Flags;
    }

    [ComImport, Guid("29038f61-3839-4626-91fd-086879011a05"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAdapter1 {
        [PreserveSig] int SetPrivateData(ref Guid name, uint size, IntPtr data);
        [PreserveSig] int SetPrivateDataInterface(ref Guid name, IntPtr unknown);
        [PreserveSig] int GetPrivateData(ref Guid name, ref uint size, IntPtr data);
        [PreserveSig] int GetParent(ref Guid riid, out IntPtr parent);
        [PreserveSig] int EnumOutputs(uint output, out IntPtr value);
        [PreserveSig] int GetDesc(IntPtr desc);
        [PreserveSig] int CheckInterfaceSupport(ref Guid name, out long version);
        [PreserveSig] int GetDesc1(out AdapterDesc1 desc);
    }

    [ComImport, Guid("770aae78-f26f-4dba-a829-253c83d1b387"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IFactory1 {
        [PreserveSig] int SetPrivateData(ref Guid name, uint size, IntPtr data);
        [PreserveSig] int SetPrivateDataInterface(ref Guid name, IntPtr unknown);
        [PreserveSig] int GetPrivateData(ref Guid name, ref uint size, IntPtr data);
        [PreserveSig] int GetParent(ref Guid riid, out IntPtr parent);
        [PreserveSig] int EnumAdapters(uint adapter, out IntPtr value);
        [PreserveSig] int MakeWindowAssociation(IntPtr window, uint flags);
        [PreserveSig] int GetWindowAssociation(out IntPtr window);
        [PreserveSig] int CreateSwapChain(IntPtr device, IntPtr desc, out IntPtr swapChain);
        [PreserveSig] int CreateSoftwareAdapter(IntPtr module, out IntPtr adapter);
        [PreserveSig] int EnumAdapters1(uint adapter, out IAdapter1 value);
        [PreserveSig] int IsCurrent();
    }

    [DllImport("dxgi.dll", CallingConvention = CallingConvention.StdCall)]
    private static extern int CreateDXGIFactory1(
        ref Guid riid,
        [MarshalAs(UnmanagedType.Interface)] out IFactory1 factory
    );

    public static CosmicDreamGpuAdapterInfo[] Read() {
        Guid iid = new Guid("770aae78-f26f-4dba-a829-253c83d1b387");
        IFactory1 factory;
        int result = CreateDXGIFactory1(ref iid, out factory);
        if (result < 0) Marshal.ThrowExceptionForHR(result);

        var adapters = new System.Collections.Generic.List<CosmicDreamGpuAdapterInfo>();
        try {
            for (uint index = 0; ; index++) {
                IAdapter1 adapter;
                result = factory.EnumAdapters1(index, out adapter);
                if (result == unchecked((int)0x887A0002)) break;
                if (result < 0) Marshal.ThrowExceptionForHR(result);
                try {
                    AdapterDesc1 desc;
                    result = adapter.GetDesc1(out desc);
                    if (result < 0) Marshal.ThrowExceptionForHR(result);
                    adapters.Add(new CosmicDreamGpuAdapterInfo {
                        Index = (int)index,
                        Id = String.Format(
                            "0x{0:X8}_0x{1:X8}",
                            unchecked((uint)desc.AdapterLuid.HighPart),
                            desc.AdapterLuid.LowPart
                        ).ToLowerInvariant(),
                        Name = (desc.Description ?? String.Empty).Trim(),
                        VendorId = desc.VendorId,
                        DeviceId = desc.DeviceId,
                        Software = (desc.Flags & 2u) != 0
                    });
                } finally {
                    Marshal.ReleaseComObject(adapter);
                }
            }
        } finally {
            Marshal.ReleaseComObject(factory);
        }
        return adapters.ToArray();
    }
}

public static class CosmicDreamMemoryStatus {
    [StructLayout(LayoutKind.Sequential)]
    private sealed class MemoryStatusEx {
        public uint Length = (uint)Marshal.SizeOf(typeof(MemoryStatusEx));
        public uint MemoryLoad;
        public ulong TotalPhysical;
        public ulong AvailablePhysical;
        public ulong TotalPageFile;
        public ulong AvailablePageFile;
        public ulong TotalVirtual;
        public ulong AvailableVirtual;
        public ulong AvailableExtendedVirtual;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GlobalMemoryStatusEx([In, Out] MemoryStatusEx status);

    public static ulong[] Read() {
        MemoryStatusEx status = new MemoryStatusEx();
        if (!GlobalMemoryStatusEx(status)) {
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        }
        return new ulong[] { status.TotalPhysical, status.AvailablePhysical };
    }
}

public sealed class CosmicDreamAudioEndpointInfo {
    public string Id { get; set; }
    public string Name { get; set; }
}

public static class CosmicDreamAudioEndpoint {
    private enum DataFlow {
        Render = 0,
        Capture = 1,
        All = 2
    }

    private enum Role {
        Console = 0,
        Multimedia = 1,
        Communications = 2
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PropertyKey {
        public Guid FormatId;
        public int PropertyId;

        public PropertyKey(Guid formatId, int propertyId) {
            FormatId = formatId;
            PropertyId = propertyId;
        }
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct PropVariant {
        [FieldOffset(0)] public ushort ValueType;
        [FieldOffset(8)] public IntPtr PointerValue;
    }

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IDeviceEnumerator {
        [PreserveSig] int EnumAudioEndpoints(DataFlow dataFlow, uint stateMask, out IntPtr devices);
        [PreserveSig] int GetDefaultAudioEndpoint(DataFlow dataFlow, Role role, out IDevice device);
        [PreserveSig] int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IDevice device);
        [PreserveSig] int RegisterEndpointNotificationCallback(IntPtr client);
        [PreserveSig] int UnregisterEndpointNotificationCallback(IntPtr client);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IDevice {
        [PreserveSig] int Activate(ref Guid interfaceId, uint context, IntPtr activationParameters, [MarshalAs(UnmanagedType.IUnknown)] out object instance);
        [PreserveSig] int OpenPropertyStore(uint accessMode, out IPropertyStore properties);
        [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
        [PreserveSig] int GetState(out uint state);
    }

    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IPropertyStore {
        [PreserveSig] int GetCount(out uint count);
        [PreserveSig] int GetAt(uint index, out PropertyKey key);
        [PreserveSig] int GetValue(ref PropertyKey key, out PropVariant value);
        [PreserveSig] int SetValue(ref PropertyKey key, ref PropVariant value);
        [PreserveSig] int Commit();
    }

    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    private class DeviceEnumeratorComObject {}

    [DllImport("ole32.dll")]
    private static extern int PropVariantClear(ref PropVariant value);

    private static void ThrowForFailure(int result) {
        if (result < 0) Marshal.ThrowExceptionForHR(result);
    }

    public static CosmicDreamAudioEndpointInfo Read() {
        IDeviceEnumerator enumerator = (IDeviceEnumerator)new DeviceEnumeratorComObject();
        IDevice device = null;
        IPropertyStore properties = null;
        PropVariant value = new PropVariant();
        bool valueInitialized = false;
        try {
            int result = enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia, out device);
            if (result < 0 || device == null) {
                device = null;
                ThrowForFailure(enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Console, out device));
            }

            string id;
            ThrowForFailure(device.GetId(out id));
            ThrowForFailure(device.OpenPropertyStore(0, out properties));
            PropertyKey friendlyName = new PropertyKey(
                new Guid("A45C254E-DF1C-4EFD-8020-67D146A850E0"),
                14
            );
            ThrowForFailure(properties.GetValue(ref friendlyName, out value));
            valueInitialized = true;
            string name = value.ValueType == 31 && value.PointerValue != IntPtr.Zero
                ? Marshal.PtrToStringUni(value.PointerValue)
                : String.Empty;
            return new CosmicDreamAudioEndpointInfo {
                Id = id ?? String.Empty,
                Name = (name ?? String.Empty).Trim()
            };
        } finally {
            if (valueInitialized) PropVariantClear(ref value);
            if (properties != null) Marshal.ReleaseComObject(properties);
            if (device != null) Marshal.ReleaseComObject(device);
            if (enumerator != null) Marshal.ReleaseComObject(enumerator);
        }
    }
}
'@

function Write-BridgeLog {
    param([string]$Message)

    if (-not $LogPath) { return }
    try {
        $directory = Split-Path -Parent $LogPath
        if ($directory -and -not (Test-Path -LiteralPath $directory)) {
            [void](New-Item -ItemType Directory -Path $directory -Force)
        }
        $line = '{0:o} {1}' -f [datetime]::UtcNow, $Message
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    } catch {}
}

function Initialize-HardwareIdentity {
    $cpuName = 'CPU'
    try {
        $names = @(
            Get-CimInstance Win32_Processor -ErrorAction Stop |
                ForEach-Object { ([string]$_.Name -replace '\s+', ' ').Trim() } |
                Where-Object { $_ } |
                Select-Object -Unique
        )
        if ($names.Count -gt 0) { $cpuName = $names -join ' / ' }
    } catch {
        Write-BridgeLog "CPU identity lookup failed: $($_.Exception.Message)"
    }

    $gpus = @()
    try {
        $gpus = @(
            [CosmicDreamDxgiAdapters]::Read() |
                Where-Object { -not $_.Software -and $_.Name } |
                ForEach-Object {
                    [ordered]@{
                        index = [int]$_.Index
                        id = [string]$_.Id
                        name = ([string]$_.Name -replace '\s+', ' ').Trim()
                        vendorId = ('0x{0:X4}' -f [uint32]$_.VendorId)
                        deviceId = ('0x{0:X4}' -f [uint32]$_.DeviceId)
                    }
                }
        )
    } catch {
        Write-BridgeLog "DXGI adapter lookup failed: $($_.Exception.Message)"
    }

    if ($gpus.Count -eq 0) {
        try {
            $gpus = @(
                Get-CimInstance Win32_VideoController -ErrorAction Stop |
                    Where-Object { $_.Name -and $_.Name -notmatch 'Basic Render|Basic Display' } |
                    ForEach-Object -Begin { $index = 0 } -Process {
                        [ordered]@{
                            index = $index++
                            id = "adapter-$index"
                            name = ([string]$_.Name -replace '\s+', ' ').Trim()
                            vendorId = $null
                            deviceId = $null
                        }
                    }
            )
        } catch {
            Write-BridgeLog "Fallback GPU identity lookup failed: $($_.Exception.Message)"
        }
    }

    $script:hardwareIdentity = [ordered]@{
        cpuName = $cpuName
        gpus = $gpus
    }
    Write-BridgeLog "Hardware identity initialized: CPU '$cpuName'; GPU count $($gpus.Count)."
}

function Initialize-WindowsMediaSession {
    try {
        Add-Type -AssemblyName System.Runtime.WindowsRuntime -ErrorAction Stop
        $script:mediaManagerType = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType=WindowsRuntime]
        $script:mediaAsTaskMethod = [System.WindowsRuntimeSystemExtensions].GetMethods() |
            Where-Object {
                $_.Name -eq 'AsTask' -and
                $_.IsGenericMethod -and
                $_.GetParameters().Count -eq 1 -and
                $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
            } |
            Select-Object -First 1
        if (-not $script:mediaAsTaskMethod) { throw 'Windows Runtime task adapter is unavailable.' }
        $operation = $script:mediaManagerType::RequestAsync()
        $task = $script:mediaAsTaskMethod.MakeGenericMethod($script:mediaManagerType).Invoke($null, @($operation))
        $script:mediaManager = $task.GetAwaiter().GetResult()
    } catch {
        $script:mediaManager = $null
        Write-BridgeLog "Windows media session unavailable: $($_.Exception.Message)"
    }
}

function Wait-WindowsRuntimeOperation {
    param(
        [Parameter(Mandatory = $true)]$Operation,
        [Parameter(Mandatory = $true)][Type]$ResultType
    )

    if (-not $script:mediaAsTaskMethod) { throw 'Windows Runtime task adapter is unavailable.' }
    $task = $script:mediaAsTaskMethod.MakeGenericMethod($ResultType).Invoke($null, @($Operation))
    return $task.GetAwaiter().GetResult()
}

function Get-BridgeCapabilities {
    $hasMediaSessionApi = $null -ne $script:mediaManager
    return [ordered]@{
        metrics = $true
        hardwareMetrics = $true
        hardwareIdentity = $true
        multiGpu = $true
        mediaControl = $false
        mediaSeek = $false
        mediaMetadata = $hasMediaSessionApi
        todoEditor = $true
        audioCapture = $false
        audioEndpointIdentity = $true
    }
}

function Get-DefaultAudioOutputDevice {
    $now = [datetime]::UtcNow
    if (
        $script:audioOutputCache -and
        ($now - $script:audioOutputCacheTimestamp).TotalMilliseconds -lt $script:audioOutputCacheLifetimeMilliseconds
    ) {
        return $script:audioOutputCache
    }

    try {
        $endpoint = [CosmicDreamAudioEndpoint]::Read()
        if (-not $endpoint -or [string]::IsNullOrWhiteSpace([string]$endpoint.Name)) {
            throw 'The default render endpoint did not expose a friendly name.'
        }
        $script:audioOutputCache = [ordered]@{
            id = [string]$endpoint.Id
            name = ([string]$endpoint.Name -replace '\s+', ' ').Trim()
        }
        $script:audioOutputCacheTimestamp = $now
    } catch {
        Write-BridgeLog "Default audio output lookup failed: $($_.Exception.Message)"
    }
    return $script:audioOutputCache
}

function Get-BridgeInfo {
    return [ordered]@{
        name = $bridgeName
        version = $bridgeVersion
        protocolVersion = 2
        port = $Port
        capabilities = Get-BridgeCapabilities
    }
}

function New-UnavailableMediaState {
    return [ordered]@{
        available = $false
    }
}

function Get-MediaState {
    if (-not $script:mediaManager) {
        return New-UnavailableMediaState
    }

    try {
        $session = $script:mediaManager.GetCurrentSession()
        if (-not $session) {
            return New-UnavailableMediaState
        }

        $propertiesType = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties, Windows.Media.Control, ContentType=WindowsRuntime]
        $properties = Wait-WindowsRuntimeOperation -Operation $session.TryGetMediaPropertiesAsync() -ResultType $propertiesType
        $playback = $session.GetPlaybackInfo()
        $status = if ($playback) { [string]$playback.PlaybackStatus } else { 'Unknown' }

        return [ordered]@{
            available = $true
            source = [string]$session.SourceAppUserModelId
            title = if ($properties) { [string]$properties.Title } else { '' }
            artist = if ($properties) { [string]$properties.Artist } else { '' }
            albumTitle = if ($properties) { [string]$properties.AlbumTitle } else { '' }
            playbackStatus = $status
            isPlaying = $status -eq 'Playing'
        }
    } catch {
        Write-BridgeLog "Media state unavailable: $($_.Exception.Message)"
        return New-UnavailableMediaState
    }
}

function Limit-Percentage {
    param([double]$Value)
    return [math]::Round([math]::Min(100, [math]::Max(0, $Value)), 1)
}

function Get-GpuAdapterPeaks {
    param([hashtable]$EngineTotals)

    $adapterPeaks = @{}
    foreach ($entry in $EngineTotals.GetEnumerator()) {
        $parts = [string]$entry.Key -split '\|', 2
        if ($parts.Count -lt 1) { continue }
        $adapterId = $parts[0].ToLowerInvariant()
        $value = Limit-Percentage ([double]$entry.Value)
        if (-not $adapterPeaks.ContainsKey($adapterId) -or $value -gt $adapterPeaks[$adapterId]) {
            $adapterPeaks[$adapterId] = $value
        }
    }
    return $adapterPeaks
}

function ConvertTo-GpuDeviceSamples {
    param([hashtable]$AdapterPeaks)

    $devices = [System.Collections.Generic.List[object]]::new()
    $identityGpus = if ($script:hardwareIdentity -and $script:hardwareIdentity.gpus) {
        @($script:hardwareIdentity.gpus)
    } else {
        @()
    }

    if ($identityGpus.Count -gt 0) {
        foreach ($adapter in $identityGpus) {
            $id = ([string]$adapter.id).ToLowerInvariant()
            $value = if ($AdapterPeaks.ContainsKey($id)) { $AdapterPeaks[$id] } else { $null }
            $devices.Add([ordered]@{
                index = [int]$adapter.index
                id = $id
                name = [string]$adapter.name
                value = $value
                unit = '%'
            })
        }
    } else {
        $index = 0
        foreach ($id in @($AdapterPeaks.Keys | Sort-Object)) {
            $devices.Add([ordered]@{
                index = $index++
                id = [string]$id
                name = "GPU $index"
                value = $AdapterPeaks[$id]
                unit = '%'
            })
        }
    }
    return $devices.ToArray()
}

function Get-AutomaticGpuDeviceSample {
    param([object[]]$Devices)

    $valid = @($Devices | Where-Object { $null -ne $_.value })
    if ($valid.Count -gt 0) {
        return $valid | Sort-Object -Property @{ Expression = { [double]$_.value }; Descending = $true }, index | Select-Object -First 1
    }
    return $Devices | Sort-Object index | Select-Object -First 1
}

function Get-QueryValue {
    param(
        [string]$RequestTarget,
        [string]$Name
    )

    $match = [regex]::Match($RequestTarget, "(?:[?&])$([regex]::Escape($Name))=([^&]*)")
    if (-not $match.Success) { return $null }
    return [System.Uri]::UnescapeDataString($match.Groups[1].Value.Replace('+', ' '))
}

function Test-WallpaperEngineConnection {
    param([System.Net.Sockets.TcpClient]$Client)

    try {
        $remoteEndpoint = [System.Net.IPEndPoint]$Client.Client.RemoteEndPoint
        $localEndpoint = [System.Net.IPEndPoint]$Client.Client.LocalEndPoint
        if (-not $remoteEndpoint -or -not $localEndpoint) { return $false }
        if (
            -not [System.Net.IPAddress]::IsLoopback($remoteEndpoint.Address) -or
            -not [System.Net.IPAddress]::IsLoopback($localEndpoint.Address)
        ) { return $false }

        $ownerPid = [CosmicDreamTcpOwner]::FindEstablishedOwner(
            $remoteEndpoint.Port,
            $localEndpoint.Port
        )
        if ($ownerPid -le 0 -or $ownerPid -eq $PID) { return $false }
        $process = Get-Process -Id $ownerPid -ErrorAction Stop
        $verified = $process.ProcessName -match '^(?:wallpaper|webwallpaper)(?:32|64)$'
        if ($verified -and $script:verifiedWallpaperProcessIds.Add([int]$ownerPid)) {
            Write-BridgeLog "Verified Wallpaper Engine client: $($process.ProcessName) ($ownerPid)."
        }
        return $verified
    } catch {
        Write-BridgeLog "Wallpaper Engine connection verification failed: $($_.Exception.Message)"
    }
    return $false
}

function Test-LocalHttpOrigin {
    param([string]$Origin)

    $uri = $null
    if (-not [System.Uri]::TryCreate($Origin, [System.UriKind]::Absolute, [ref]$uri)) {
        return $false
    }
    return (
        $uri.Scheme -eq 'http' -and
        $uri.Host -in @('127.0.0.1', 'localhost') -and
        [string]::IsNullOrEmpty($uri.UserInfo) -and
        $uri.AbsolutePath -eq '/' -and
        [string]::IsNullOrEmpty($uri.Query) -and
        [string]::IsNullOrEmpty($uri.Fragment)
    )
}

function Get-OriginDecision {
    param(
        [System.Collections.Generic.Dictionary[string, string]]$Headers,
        [System.Net.Sockets.TcpClient]$Client
    )

    if (-not $Headers.ContainsKey('Origin')) {
        return [ordered]@{ allowed = $true; allowOrigin = '' }
    }

    $origin = $Headers['Origin']
    if (Test-LocalHttpOrigin -Origin $origin) {
        return [ordered]@{ allowed = $true; allowOrigin = $origin }
    }

    $isNullOrFileOrigin = (
        $origin.Equals('null', [System.StringComparison]::OrdinalIgnoreCase) -or
        $origin.StartsWith('file:', [System.StringComparison]::OrdinalIgnoreCase)
    )
    if ($isNullOrFileOrigin -and (Test-WallpaperEngineConnection -Client $Client)) {
        return [ordered]@{ allowed = $true; allowOrigin = $origin }
    }

    return [ordered]@{ allowed = $false; allowOrigin = '' }
}

function Show-TodoEditor {
    param(
        [string]$Id,
        [string]$Title,
        [string]$Notes,
        [string]$DueDate,
        [string]$Priority,
        [bool]$Done,
        [long]$CreatedAt,
        [bool]$IsNew
    )

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $form = [System.Windows.Forms.Form]::new()
    $form.Text = 'Cosmic Dream / W01 Objective Editor'
    $form.ClientSize = [System.Drawing.Size]::new(540, 470)
    $form.MinimumSize = [System.Drawing.Size]::new(556, 509)
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ShowInTaskbar = $true
    $form.TopMost = $true
    $form.BackColor = [System.Drawing.Color]::FromArgb(10, 14, 17)
    $form.ForeColor = [System.Drawing.Color]::FromArgb(176, 239, 247)
    $form.Font = [System.Drawing.Font]::new('Microsoft YaHei UI', 9)

    $header = [System.Windows.Forms.Label]::new()
    $header.Text = 'W01 / OBJECTIVE CONTROL'
    $header.Location = [System.Drawing.Point]::new(24, 18)
    $header.Size = [System.Drawing.Size]::new(490, 24)
    $header.Font = [System.Drawing.Font]::new('Consolas', 12, [System.Drawing.FontStyle]::Bold)
    $header.ForeColor = [System.Drawing.Color]::FromArgb(92, 234, 255)
    $form.Controls.Add($header)

    $titleLabel = [System.Windows.Forms.Label]::new()
    $titleLabel.Text = 'Title'
    $titleLabel.Location = [System.Drawing.Point]::new(24, 62)
    $titleLabel.AutoSize = $true
    $form.Controls.Add($titleLabel)

    $titleInput = [System.Windows.Forms.TextBox]::new()
    $titleInput.Text = $Title
    $titleInput.Location = [System.Drawing.Point]::new(24, 84)
    $titleInput.Size = [System.Drawing.Size]::new(492, 28)
    $titleInput.MaxLength = 48
    $titleInput.BackColor = [System.Drawing.Color]::FromArgb(18, 28, 34)
    $titleInput.ForeColor = [System.Drawing.Color]::White
    $titleInput.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $form.Controls.Add($titleInput)

    $dueLabel = [System.Windows.Forms.Label]::new()
    $dueLabel.Text = 'Deadline'
    $dueLabel.Location = [System.Drawing.Point]::new(24, 128)
    $dueLabel.AutoSize = $true
    $form.Controls.Add($dueLabel)

    $duePicker = [System.Windows.Forms.DateTimePicker]::new()
    $duePicker.Location = [System.Drawing.Point]::new(24, 150)
    $duePicker.Size = [System.Drawing.Size]::new(230, 28)
    $duePicker.Format = [System.Windows.Forms.DateTimePickerFormat]::Custom
    $duePicker.CustomFormat = 'yyyy-MM-dd'
    $duePicker.ShowCheckBox = $true
    $duePicker.Checked = $false
    $parsedDue = [datetime]::MinValue
    if ([datetime]::TryParseExact($DueDate, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsedDue)) {
        $duePicker.Value = $parsedDue
        $duePicker.Checked = $true
    }
    $form.Controls.Add($duePicker)

    $priorityLabel = [System.Windows.Forms.Label]::new()
    $priorityLabel.Text = 'Priority'
    $priorityLabel.Location = [System.Drawing.Point]::new(278, 128)
    $priorityLabel.AutoSize = $true
    $form.Controls.Add($priorityLabel)

    $priorityInput = [System.Windows.Forms.ComboBox]::new()
    $priorityInput.Location = [System.Drawing.Point]::new(278, 150)
    $priorityInput.Size = [System.Drawing.Size]::new(238, 28)
    $priorityInput.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    [void]$priorityInput.Items.AddRange(@('low', 'normal', 'high'))
    $priorityIndex = @('low', 'normal', 'high').IndexOf($Priority)
    $priorityInput.SelectedIndex = if ($priorityIndex -ge 0) { $priorityIndex } else { 1 }
    $form.Controls.Add($priorityInput)

    $notesLabel = [System.Windows.Forms.Label]::new()
    $notesLabel.Text = 'Notes'
    $notesLabel.Location = [System.Drawing.Point]::new(24, 198)
    $notesLabel.AutoSize = $true
    $form.Controls.Add($notesLabel)

    $notesInput = [System.Windows.Forms.TextBox]::new()
    $notesInput.Text = $Notes
    $notesInput.Location = [System.Drawing.Point]::new(24, 220)
    $notesInput.Size = [System.Drawing.Size]::new(492, 126)
    $notesInput.MaxLength = 96
    $notesInput.Multiline = $true
    $notesInput.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $notesInput.BackColor = [System.Drawing.Color]::FromArgb(18, 28, 34)
    $notesInput.ForeColor = [System.Drawing.Color]::White
    $notesInput.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $form.Controls.Add($notesInput)

    $doneInput = [System.Windows.Forms.CheckBox]::new()
    $doneInput.Text = 'Completed'
    $doneInput.Checked = $Done
    $doneInput.Location = [System.Drawing.Point]::new(24, 362)
    $doneInput.AutoSize = $true
    $form.Controls.Add($doneInput)

    $saveButton = [System.Windows.Forms.Button]::new()
    $saveButton.Text = 'Save'
    $saveButton.Location = [System.Drawing.Point]::new(406, 408)
    $saveButton.Size = [System.Drawing.Size]::new(110, 36)
    $saveButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $saveButton.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(92, 234, 255)
    $saveButton.ForeColor = [System.Drawing.Color]::FromArgb(190, 247, 255)
    $form.Controls.Add($saveButton)

    $cancelButton = [System.Windows.Forms.Button]::new()
    $cancelButton.Text = 'Cancel'
    $cancelButton.Location = [System.Drawing.Point]::new(282, 408)
    $cancelButton.Size = [System.Drawing.Size]::new(110, 36)
    $cancelButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $cancelButton.ForeColor = [System.Drawing.Color]::FromArgb(176, 198, 204)
    $form.Controls.Add($cancelButton)

    $deleteButton = [System.Windows.Forms.Button]::new()
    $deleteButton.Text = 'Delete'
    $deleteButton.Location = [System.Drawing.Point]::new(24, 408)
    $deleteButton.Size = [System.Drawing.Size]::new(110, 36)
    $deleteButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $deleteButton.ForeColor = [System.Drawing.Color]::FromArgb(255, 138, 138)
    $deleteButton.Visible = -not $IsNew
    $form.Controls.Add($deleteButton)

    $result = [ordered]@{ action = 'cancel' }
    $saveButton.Add_Click({
        $cleanTitle = $titleInput.Text.Trim()
        if (-not $cleanTitle) {
            [void][System.Windows.Forms.MessageBox]::Show(
                $form,
                'A task title is required.',
                'Cosmic Dream',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
            [void]$titleInput.Focus()
            return
        }
        $dueValue = if ($duePicker.Checked) {
            $duePicker.Value.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
        } else {
            ''
        }
        $result['action'] = 'save'
        $result['task'] = [ordered]@{
            id = $Id
            text = $cleanTitle
            notes = $notesInput.Text.Trim()
            dueDate = $dueValue
            priority = [string]$priorityInput.SelectedItem
            done = [bool]$doneInput.Checked
            createdAt = $CreatedAt
        }
        $form.Close()
    })
    $cancelButton.Add_Click({ $form.Close() })
    $deleteButton.Add_Click({
        $confirm = [System.Windows.Forms.MessageBox]::Show(
            $form,
            'Delete this objective?',
            'Cosmic Dream',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        if ($confirm -eq [System.Windows.Forms.DialogResult]::Yes) {
            $result['action'] = 'delete'
            $result['id'] = $Id
            $form.Close()
        }
    })

    $form.AcceptButton = $saveButton
    $form.CancelButton = $cancelButton
    $form.Add_Shown({ [void]$titleInput.Focus() })
    [void]$form.ShowDialog()
    $form.Dispose()
    return $result
}

function Initialize-HardwareSampler {
    try {
        $cpuCategory = $null
        $cpuCounterName = $null
        foreach ($candidate in @(
            @('Processor Information', '% Processor Utility'),
            @('Processor', '% Processor Time')
        )) {
            try {
                if (-not [System.Diagnostics.PerformanceCounterCategory]::Exists($candidate[0])) { continue }
                $category = [System.Diagnostics.PerformanceCounterCategory]::new($candidate[0])
                $snapshot = $category.ReadCategory()
                if ($snapshot.Contains($candidate[1])) {
                    $cpuCategory = $category
                    $cpuCounterName = $candidate[1]
                    $cpuPrevious = $snapshot
                    break
                }
            } catch {}
        }
        if (-not $cpuCategory) { throw 'No supported CPU performance counter category is available.' }

        $networkCategory = $null
        $networkPrevious = $null
        try {
            if ([System.Diagnostics.PerformanceCounterCategory]::Exists('Network Interface')) {
                $networkCategory = [System.Diagnostics.PerformanceCounterCategory]::new('Network Interface')
                $networkPrevious = $networkCategory.ReadCategory()
            }
        } catch {
            $networkCategory = $null
            $networkPrevious = $null
        }

        $gpuCategory = $null
        $gpuPrevious = $null
        try {
            if ([System.Diagnostics.PerformanceCounterCategory]::Exists('GPU Engine')) {
                $gpuCategory = [System.Diagnostics.PerformanceCounterCategory]::new('GPU Engine')
                $gpuPrevious = $gpuCategory.ReadCategory()
            }
        } catch {
            $gpuCategory = $null
            $gpuPrevious = $null
        }

        $script:hardwareSampler = [pscustomobject]@{
            CpuCategory = $cpuCategory
            CpuCounterName = $cpuCounterName
            CpuPrevious = $cpuPrevious
            NetworkCategory = $networkCategory
            NetworkPrevious = $networkPrevious
            GpuCategory = $gpuCategory
            GpuPrevious = $gpuPrevious
        }
        $script:hardwareSamplerMode = 'PERF COUNTER'
        Write-BridgeLog 'Hardware sampler initialized with persistent performance counters.'
    } catch {
        $script:hardwareSampler = $null
        $script:hardwareSamplerMode = 'LEGACY CIM'
        Write-BridgeLog "Fast hardware sampler unavailable; using CIM fallback: $($_.Exception.Message)"
    }
}

function Add-HardwareSamplerError {
    param([string]$Message)

    if ($script:hardwareSamplerLastError) {
        $script:hardwareSamplerLastError = "$($script:hardwareSamplerLastError); $Message"
    } else {
        $script:hardwareSamplerLastError = $Message
    }
}

function Reset-GpuHardwareSampler {
    try {
        if (-not [System.Diagnostics.PerformanceCounterCategory]::Exists('GPU Engine')) {
            throw 'GPU Engine performance counter category is unavailable.'
        }
        $category = [System.Diagnostics.PerformanceCounterCategory]::new('GPU Engine')
        $snapshot = $category.ReadCategory()
        if (-not $snapshot.Contains('Utilization Percentage')) {
            throw 'GPU utilization counter is unavailable.'
        }
        $script:hardwareSampler.GpuCategory = $category
        $script:hardwareSampler.GpuPrevious = $snapshot
        $script:gpuSamplerConsecutiveFailures = 0
        Write-BridgeLog 'GPU performance counter sampler was rebuilt.'
        return $true
    } catch {
        Add-HardwareSamplerError "gpu reset: $($_.Exception.Message)"
        Write-BridgeLog "GPU performance counter reset failed: $($_.Exception.Message)"
        return $false
    }
}

function Read-FastHardwareMetrics {
    if (-not $script:hardwareSampler) { return $null }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $script:hardwareSamplerLastError = $null
    $cpu = $null
    $memory = $null
    $memoryUsedGB = $null
    $memoryTotalGB = $null
    $network = $null
    $gpu = $null
    $gpuName = $null
    $gpuDevices = @(ConvertTo-GpuDeviceSamples -AdapterPeaks @{})
    $gpuSampleValid = $false

    try {
        $cpuCurrent = $script:hardwareSampler.CpuCategory.ReadCategory()
        $currentCounter = $cpuCurrent[$script:hardwareSampler.CpuCounterName]
        $previousCounter = $script:hardwareSampler.CpuPrevious[$script:hardwareSampler.CpuCounterName]
        if ($currentCounter -and $previousCounter -and $currentCounter.Contains('_Total') -and $previousCounter.Contains('_Total')) {
            $value = [System.Diagnostics.CounterSample]::Calculate(
                $previousCounter['_Total'].Sample,
                $currentCounter['_Total'].Sample
            )
            if (-not [double]::IsNaN($value) -and -not [double]::IsInfinity($value)) {
                $cpu = Limit-Percentage ([double]$value)
            }
        }
        $script:hardwareSampler.CpuPrevious = $cpuCurrent
    } catch {
        $script:hardwareSamplerLastError = "cpu: $($_.Exception.Message)"
    }

    try {
        $memoryStatus = [CosmicDreamMemoryStatus]::Read()
        $total = [double]$memoryStatus[0]
        $available = [double]$memoryStatus[1]
        if ($total -gt 0 -and $available -ge 0) {
            $used = [math]::Max(0.0, $total - $available)
            $memory = Limit-Percentage (($used / $total) * 100)
            $memoryUsedGB = [math]::Round(($used / 1GB), 2)
            $memoryTotalGB = [math]::Round(($total / 1GB), 2)
        }
    } catch {
        $script:hardwareSamplerLastError = "memory: $($_.Exception.Message)"
    }

    if ($script:hardwareSampler.NetworkCategory -and $script:hardwareSampler.NetworkPrevious) {
        try {
            $networkCurrent = $script:hardwareSampler.NetworkCategory.ReadCategory()
            $currentCounter = $networkCurrent['Bytes Total/sec']
            $previousCounter = $script:hardwareSampler.NetworkPrevious['Bytes Total/sec']
            $busiestInterface = 0.0
            if ($currentCounter -and $previousCounter) {
                foreach ($instanceName in $currentCounter.Keys) {
                    if (-not $previousCounter.Contains($instanceName)) { continue }
                    $value = [System.Diagnostics.CounterSample]::Calculate(
                        $previousCounter[$instanceName].Sample,
                        $currentCounter[$instanceName].Sample
                    )
                    if (-not [double]::IsNaN($value) -and -not [double]::IsInfinity($value) -and $value -gt $busiestInterface) {
                        $busiestInterface = [double]$value
                    }
                }
            }
            $network = [math]::Round(($busiestInterface * 8 / 1000000), 2)
            $script:hardwareSampler.NetworkPrevious = $networkCurrent
        } catch {
            $network = $null
        }
    }

    if ($script:hardwareSampler.GpuCategory -and $script:hardwareSampler.GpuPrevious) {
        try {
            $gpuCurrent = $script:hardwareSampler.GpuCategory.ReadCategory()
            $currentCounter = $gpuCurrent['Utilization Percentage']
            $previousCounter = $script:hardwareSampler.GpuPrevious['Utilization Percentage']
            $engineTotals = @{}
            if ($currentCounter -and $previousCounter) {
                foreach ($instanceName in $currentCounter.Keys) {
                    if (-not $previousCounter.Contains($instanceName)) { continue }
                    $value = [System.Diagnostics.CounterSample]::Calculate(
                        $previousCounter[$instanceName].Sample,
                        $currentCounter[$instanceName].Sample
                    )
                    if ([double]::IsNaN($value) -or [double]::IsInfinity($value) -or $value -lt 0) { continue }
                    $match = [regex]::Match(
                    [string]$instanceName,
                    '(?i)luid_(?<luid>0x[0-9a-f]+_0x[0-9a-f]+)_phys_(?<phys>\d+)_eng_(?<eng>\d+)'
                )
                    if (-not $match.Success) { continue }
                    $engineKey = '{0}|{1}|{2}' -f (
                        $match.Groups['luid'].Value,
                        $match.Groups['phys'].Value,
                        $match.Groups['eng'].Value
                    )
                    if (-not $engineTotals.ContainsKey($engineKey)) { $engineTotals[$engineKey] = 0.0 }
                    $engineTotals[$engineKey] += [double]$value
                }
            }
            $adapterPeaks = Get-GpuAdapterPeaks -EngineTotals $engineTotals
            $gpuDevices = @(ConvertTo-GpuDeviceSamples -AdapterPeaks $adapterPeaks)
            $automaticGpu = Get-AutomaticGpuDeviceSample -Devices $gpuDevices
            if ($automaticGpu) {
                $gpuName = [string]$automaticGpu.name
                if ($null -ne $automaticGpu.value) {
                    $gpu = [double]$automaticGpu.value
                    $gpuSampleValid = $true
                }
            }
            $script:hardwareSampler.GpuPrevious = $gpuCurrent
        } catch {
            $gpu = $null
            Add-HardwareSamplerError "gpu: $($_.Exception.Message)"
        }
    }

    if ($gpuSampleValid) {
        $script:gpuSamplerConsecutiveFailures = 0
    } else {
        $script:gpuSamplerConsecutiveFailures++
        if ($script:hardwareSamplerLastError -notmatch '(?:^|; )gpu(?: reset)?:') {
            Add-HardwareSamplerError 'gpu: no valid GPU Engine samples'
        }
        if ($script:gpuSamplerConsecutiveFailures -ge $script:gpuSamplerResetThreshold) {
            [void](Reset-GpuHardwareSampler)
        }
    }

    $stopwatch.Stop()
    $script:hardwareSamplerLastDurationMilliseconds = [math]::Round($stopwatch.Elapsed.TotalMilliseconds, 2)
    return [ordered]@{
        gpu = $gpu
        gpuName = $gpuName
        gpuDevices = $gpuDevices
        cpu = $cpu
        cpuName = if ($script:hardwareIdentity) { [string]$script:hardwareIdentity.cpuName } else { 'CPU' }
        memory = $memory
        memoryUsedGB = $memoryUsedGB
        memoryTotalGB = $memoryTotalGB
        network = $network
        source = 'WINDOWS PDH'
    }
}

function Read-LegacyHardwareMetrics {
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $cpu = $null
    $memory = $null
    $memoryUsedGB = $null
    $memoryTotalGB = $null
    $network = $null
    $gpu = $null
    $gpuName = $null
    $gpuDevices = @(ConvertTo-GpuDeviceSamples -AdapterPeaks @{})

    try {
        $processor = Get-CimInstance Win32_PerfFormattedData_Counters_ProcessorInformation -Filter "Name='_Total'"
        if ($processor -and $null -ne $processor.PercentProcessorUtility) {
            $cpu = Limit-Percentage ([double]$processor.PercentProcessorUtility)
        }
    } catch {}
    if ($null -eq $cpu) {
        try {
            $processor = Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'"
            if ($processor) { $cpu = Limit-Percentage ([double]$processor.PercentProcessorTime) }
        } catch {}
    }

    try {
        $os = Get-CimInstance Win32_OperatingSystem
        $memoryCounter = $null
        try { $memoryCounter = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory } catch {}
        $total = [double]$os.TotalVisibleMemorySize
        if ($total -gt 0) {
            $available = if ($memoryCounter -and $null -ne $memoryCounter.AvailableBytes) {
                [double]$memoryCounter.AvailableBytes / 1KB
            } else {
                [double]$os.FreePhysicalMemory
            }
            $used = [math]::Max(0, $total - $available)
            $memory = Limit-Percentage (($used / $total) * 100)
            $memoryUsedGB = [math]::Round(($used / 1MB), 2)
            $memoryTotalGB = [math]::Round(($total / 1MB), 2)
        }
    } catch {}

    try {
        $interface = Get-CimInstance Win32_PerfFormattedData_Tcpip_NetworkInterface |
            Where-Object { $null -ne $_.BytesTotalPersec -and [double]$_.CurrentBandwidth -gt 0 } |
            Sort-Object -Property BytesTotalPersec -Descending |
            Select-Object -First 1
        if ($interface) {
            $network = [math]::Round(([double]$interface.BytesTotalPersec * 8 / 1000000), 2)
        }
    } catch {}

    try {
        $engines = @(Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine)
        if ($engines) {
            $engineTotals = @{}
            foreach ($engine in $engines) {
                $match = [regex]::Match(
                    [string]$engine.Name,
                    '(?i)luid_(?<luid>0x[0-9a-f]+_0x[0-9a-f]+)_phys_(?<phys>\d+)_eng_(?<eng>\d+)'
                )
                if (-not $match.Success) { continue }
                $engineKey = '{0}|{1}|{2}' -f (
                    $match.Groups['luid'].Value,
                    $match.Groups['phys'].Value,
                    $match.Groups['eng'].Value
                )
                if (-not $engineTotals.ContainsKey($engineKey)) { $engineTotals[$engineKey] = 0.0 }
                $engineTotals[$engineKey] += [double]$engine.UtilizationPercentage
            }
            $adapterPeaks = Get-GpuAdapterPeaks -EngineTotals $engineTotals
            $gpuDevices = @(ConvertTo-GpuDeviceSamples -AdapterPeaks $adapterPeaks)
            $automaticGpu = Get-AutomaticGpuDeviceSample -Devices $gpuDevices
            if ($automaticGpu) {
                $gpuName = [string]$automaticGpu.name
                if ($null -ne $automaticGpu.value) { $gpu = [double]$automaticGpu.value }
            }
        }
    } catch {}

    $stopwatch.Stop()
    $script:hardwareSamplerLastDurationMilliseconds = [math]::Round($stopwatch.Elapsed.TotalMilliseconds, 2)
    return [ordered]@{
        gpu = $gpu
        gpuName = $gpuName
        gpuDevices = $gpuDevices
        cpu = $cpu
        cpuName = if ($script:hardwareIdentity) { [string]$script:hardwareIdentity.cpuName } else { 'CPU' }
        memory = $memory
        memoryUsedGB = $memoryUsedGB
        memoryTotalGB = $memoryTotalGB
        network = $network
        source = 'WINDOWS PERF'
    }
}

function Read-HardwareSnapshot {
    $now = [datetime]::UtcNow
    if (
        $script:hardwareCache -and
        ($now - $script:hardwareCacheTimestamp).TotalMilliseconds -lt $script:hardwareCacheLifetimeMilliseconds
    ) {
        return $script:hardwareCache
    }

    $sample = if ($script:hardwareSampler) {
        Read-FastHardwareMetrics
    } else {
        Read-LegacyHardwareMetrics
    }
    if (-not $sample) { $sample = Read-LegacyHardwareMetrics }

    $sampledAt = [datetime]::UtcNow
    $script:hardwareSampleId++
    $script:hardwareCache = [ordered]@{
        metrics = [ordered]@{
            gpu = [ordered]@{
                value = $sample.gpu
                title = $sample.gpuName
                unit = '%'
                max = 100
                source = $sample.source
                devices = @($sample.gpuDevices)
            }
            cpu = [ordered]@{
                value = $sample.cpu
                title = $sample.cpuName
                unit = '%'
                max = 100
                source = $sample.source
            }
            memory = [ordered]@{
                value = $sample.memory
                unit = '%'
                max = 100
                absoluteValue = $sample.memoryUsedGB
                absoluteMax = $sample.memoryTotalGB
                absoluteUnit = 'GB'
                source = 'WINDOWS OS'
            }
            network = [ordered]@{ value = $sample.network; unit = 'MBPS'; source = $sample.source }
        }
        timestamp = $sampledAt.ToString('o')
        sampleId = $script:hardwareSampleId
        collector = [ordered]@{
            mode = $script:hardwareSamplerMode
            durationMilliseconds = $script:hardwareSamplerLastDurationMilliseconds
            cacheMilliseconds = $script:hardwareCacheLifetimeMilliseconds
            lastError = $script:hardwareSamplerLastError
        }
        bridge = Get-BridgeInfo
    }
    $script:hardwareCacheTimestamp = $sampledAt
    return $script:hardwareCache
}

function Read-MediaSnapshot {
    $now = [datetime]::UtcNow
    if ($script:mediaCache -and ($now - $script:mediaCacheTimestamp).TotalMilliseconds -lt 250) {
        return $script:mediaCache
    }

    $media = Get-MediaState
    $outputDevice = Get-DefaultAudioOutputDevice
    $media['outputDevice'] = if ($outputDevice) { [string]$outputDevice.name } else { '' }
    $media['outputDeviceId'] = if ($outputDevice) { [string]$outputDevice.id } else { '' }
    $sampledAt = [datetime]::UtcNow
    $script:mediaSampleId++
    $script:mediaCache = [ordered]@{
        media = $media
        timestamp = $sampledAt.ToString('o')
        sampleId = $script:mediaSampleId
        bridge = Get-BridgeInfo
    }
    $script:mediaCacheTimestamp = $sampledAt
    return $script:mediaCache
}

function Read-SystemMetrics {
    $hardware = Read-HardwareSnapshot
    $media = Read-MediaSnapshot
    return [ordered]@{
        metrics = $hardware.metrics
        media = $media.media
        timestamp = [datetime]::UtcNow.ToString('o')
        bridge = $hardware.bridge
    }
}

function Write-HttpResponse {
    param(
        [System.IO.Stream]$Stream,
        [int]$Status,
        [string]$StatusText,
        [string]$Body = '',
        [string]$AllowOrigin = '',
        [string]$ContentType = 'application/json; charset=utf-8'
    )

    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
    $headers = [System.Collections.Generic.List[string]]::new()
    $headers.Add("HTTP/1.1 $Status $StatusText")
    $headers.Add("Content-Type: $ContentType")
    $headers.Add("Content-Length: $($bodyBytes.Length)")
    if ($AllowOrigin) { $headers.Add("Access-Control-Allow-Origin: $AllowOrigin") }
    $headers.Add('Access-Control-Allow-Methods: GET, POST, OPTIONS')
    $headers.Add('Access-Control-Allow-Headers: Content-Type, X-Cosmic-Dream-Client')
    $headers.Add('Access-Control-Allow-Private-Network: true')
    $headers.Add('Cache-Control: no-store')
    $headers.Add('X-Content-Type-Options: nosniff')
    $headers.Add('Vary: Origin')
    $headers.Add('Connection: close')
    $headers.Add('')
    $headers.Add('')
    $headerBytes = [System.Text.Encoding]::ASCII.GetBytes(($headers -join "`r`n"))
    $Stream.Write($headerBytes, 0, $headerBytes.Length)
    if ($bodyBytes.Length -gt 0) { $Stream.Write($bodyBytes, 0, $bodyBytes.Length) }
    $Stream.Flush()
}

try {
    $createdNew = $false
    $mutex = [System.Threading.Mutex]::new($true, "Local\CosmicDreamBridge-$Port", [ref]$createdNew)
    if (-not $createdNew) {
        Write-BridgeLog "Bridge already running on port $Port."
        exit 0
    }
    $ownsMutex = $true

    Initialize-WindowsMediaSession
    Initialize-HardwareIdentity
    Initialize-HardwareSampler

    $listener.Start()
    Write-BridgeLog "Started $bridgeName $bridgeVersion on 127.0.0.1:$Port."
    Write-Host "$bridgeName $bridgeVersion"
    Write-Host "Health:  http://127.0.0.1:$Port/v1/health"
    Write-Host "Metrics: http://127.0.0.1:$Port/v1/metrics"
    Write-Host "Hardware: http://127.0.0.1:$Port/v1/hardware"
    Write-Host "Media:    http://127.0.0.1:$Port/v1/media"
    Write-Host 'Listening on loopback only. Press Ctrl+C to stop.'

    while ($true) {
        $client = $null
        $stream = $null
        $reader = $null
        try {
            $client = $listener.AcceptTcpClient()
            $client.ReceiveTimeout = 2500
            $client.SendTimeout = 2500
            $stream = $client.GetStream()
            $reader = [System.IO.StreamReader]::new(
                $stream,
                [System.Text.Encoding]::ASCII,
                $false,
                1024,
                $true
            )
            $requestLine = $reader.ReadLine()
            $requestHeaders = [System.Collections.Generic.Dictionary[string, string]]::new(
                [System.StringComparer]::OrdinalIgnoreCase
            )
            while (($line = $reader.ReadLine()) -ne $null -and $line -ne '') {
                $separator = $line.IndexOf(':')
                if ($separator -gt 0) {
                    $name = $line.Substring(0, $separator).Trim()
                    $value = $line.Substring($separator + 1).Trim()
                    $requestHeaders[$name] = $value
                }
            }

            $parts = @($requestLine -split ' ')
            $method = if ($parts.Count -gt 0) { $parts[0].ToUpperInvariant() } else { '' }
            $requestTarget = if ($parts.Count -gt 1) { $parts[1] } else { '' }
            $path = $requestTarget.Split('?')[0]
            $originDecision = Get-OriginDecision -Headers $requestHeaders -Client $client
            $allowOrigin = $originDecision.allowOrigin

            if (-not $originDecision.allowed) {
                Write-HttpResponse -Stream $stream -Status 403 -StatusText 'Forbidden' -Body '{"error":"origin not allowed"}'
            } elseif ($method -eq 'OPTIONS') {
                Write-HttpResponse -Stream $stream -Status 204 -StatusText 'No Content' -AllowOrigin $allowOrigin
            } elseif ($method -eq 'GET' -and $path -eq '/v1/health') {
                $json = [ordered]@{
                    ok = $true
                    name = $bridgeName
                    version = $bridgeVersion
                    protocolVersion = 2
                    hardwareEndpoint = '/v1/hardware'
                    mediaEndpoint = '/v1/media'
                    port = $Port
                    uptimeSeconds = [math]::Floor(([datetime]::UtcNow - $startedAt).TotalSeconds)
                    capabilities = Get-BridgeCapabilities
                } | ConvertTo-Json -Depth 4 -Compress
                Write-HttpResponse -Stream $stream -Status 200 -StatusText 'OK' -Body $json -AllowOrigin $allowOrigin
            } elseif ($method -eq 'GET' -and $path -eq '/v1/hardware') {
                $json = Read-HardwareSnapshot | ConvertTo-Json -Depth 6 -Compress
                Write-HttpResponse -Stream $stream -Status 200 -StatusText 'OK' -Body $json -AllowOrigin $allowOrigin
            } elseif ($method -eq 'GET' -and $path -eq '/v1/media') {
                $json = Read-MediaSnapshot | ConvertTo-Json -Depth 6 -Compress
                Write-HttpResponse -Stream $stream -Status 200 -StatusText 'OK' -Body $json -AllowOrigin $allowOrigin
            } elseif ($method -eq 'GET' -and $path -eq '/v1/metrics') {
                $json = Read-SystemMetrics | ConvertTo-Json -Depth 6 -Compress
                Write-HttpResponse -Stream $stream -Status 200 -StatusText 'OK' -Body $json -AllowOrigin $allowOrigin
            } elseif ($method -eq 'POST' -and $path -eq '/v1/todo/editor') {
                $clientHeader = if ($requestHeaders.ContainsKey('X-Cosmic-Dream-Client')) {
                    $requestHeaders['X-Cosmic-Dream-Client']
                } else {
                    ''
                }
                if ($clientHeader -ne 'wallpaper-v1') {
                    Write-HttpResponse -Stream $stream -Status 403 -StatusText 'Forbidden' -Body '{"error":"client not allowed"}' -AllowOrigin $allowOrigin
                    continue
                }
                $createdAt = 0L
                [void][long]::TryParse((Get-QueryValue -RequestTarget $requestTarget -Name 'createdAt'), [ref]$createdAt)
                if ($createdAt -le 0) { $createdAt = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
                $editorResult = Show-TodoEditor `
                    -Id (Get-QueryValue -RequestTarget $requestTarget -Name 'id') `
                    -Title (Get-QueryValue -RequestTarget $requestTarget -Name 'title') `
                    -Notes (Get-QueryValue -RequestTarget $requestTarget -Name 'notes') `
                    -DueDate (Get-QueryValue -RequestTarget $requestTarget -Name 'dueDate') `
                    -Priority (Get-QueryValue -RequestTarget $requestTarget -Name 'priority') `
                    -Done ((Get-QueryValue -RequestTarget $requestTarget -Name 'done') -eq '1') `
                    -CreatedAt $createdAt `
                    -IsNew ((Get-QueryValue -RequestTarget $requestTarget -Name 'isNew') -eq '1')
                $json = $editorResult | ConvertTo-Json -Depth 5 -Compress
                Write-HttpResponse -Stream $stream -Status 200 -StatusText 'OK' -Body $json -AllowOrigin $allowOrigin
            } elseif ($method -eq 'GET' -and $path -eq '/v1/diagnostics') {
                $json = [ordered]@{
                    cacheTimestamp = if ($script:hardwareCacheTimestamp -eq [datetime]::MinValue) { $null } else { $script:hardwareCacheTimestamp.ToString('o') }
                    hardwareCacheTimestamp = if ($script:hardwareCacheTimestamp -eq [datetime]::MinValue) { $null } else { $script:hardwareCacheTimestamp.ToString('o') }
                    hardwareSampleId = $script:hardwareSampleId
                    hardwareSamplerMode = $script:hardwareSamplerMode
                    hardwareSamplerDurationMilliseconds = $script:hardwareSamplerLastDurationMilliseconds
                    hardwareCacheMilliseconds = $script:hardwareCacheLifetimeMilliseconds
                    hardwareSamplerLastError = $script:hardwareSamplerLastError
                    gpuSamplerConsecutiveFailures = $script:gpuSamplerConsecutiveFailures
                    mediaCacheTimestamp = if ($script:mediaCacheTimestamp -eq [datetime]::MinValue) { $null } else { $script:mediaCacheTimestamp.ToString('o') }
                    mediaSampleId = $script:mediaSampleId
                } | ConvertTo-Json -Depth 4 -Compress
                Write-HttpResponse -Stream $stream -Status 200 -StatusText 'OK' -Body $json -AllowOrigin $allowOrigin
            } else {
                Write-HttpResponse -Stream $stream -Status 404 -StatusText 'Not Found' -Body '{"error":"not found"}' -AllowOrigin $allowOrigin
            }
        } catch {
            Write-BridgeLog "Request failed: $($_.Exception.Message)"
            try {
                if ($stream -and $stream.CanWrite) {
                    Write-HttpResponse -Stream $stream -Status 500 -StatusText 'Internal Server Error' -Body '{"error":"request failed"}'
                }
            } catch {}
        } finally {
            if ($reader) { $reader.Dispose() }
            if ($stream) { $stream.Dispose() }
            if ($client) { $client.Dispose() }
        }
    }
} finally {
    Write-BridgeLog 'Stopped.'
    $listener.Stop()
    if ($ownsMutex -and $mutex) {
        try { $mutex.ReleaseMutex() } catch {}
    }
    if ($mutex) { $mutex.Dispose() }
}
