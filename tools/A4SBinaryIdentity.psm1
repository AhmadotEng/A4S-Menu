Set-StrictMode -Version 2.0

if (-not ('A4SBinaryIdentityNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;

public static class A4SBinaryIdentityNative
{
    [StructLayout(LayoutKind.Sequential)]
    private struct LUID { public uint LowPart; public int HighPart; }

    [StructLayout(LayoutKind.Sequential)]
    private struct TOKEN_STATISTICS
    {
        public LUID TokenId;
        public LUID AuthenticationId;
        public long ExpirationTime;
        public int TokenType;
        public int ImpersonationLevel;
        public uint DynamicCharged;
        public uint DynamicAvailable;
        public uint GroupCount;
        public uint PrivilegeCount;
        public LUID ModifiedId;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(uint desiredAccess, bool inheritHandle, uint processId);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool ReadProcessMemory(IntPtr process, IntPtr address, [Out] byte[] buffer,
        UIntPtr size, out UIntPtr bytesRead);

    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool OpenProcessToken(IntPtr process, uint desiredAccess, out IntPtr token);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool GetTokenInformation(IntPtr token, int informationClass,
        IntPtr information, int informationLength, out int returnLength);

    private sealed class PeHeaders
    {
        public int OptionalOffset;
        public int SectionOffset;
        public ushort SectionCount;
        public uint TimeDateStamp;
        public uint SizeOfImage;
        public uint Checksum;
        public uint DebugRva;
        public uint DebugSize;
    }

    private static ushort U16(byte[] bytes, int offset)
    {
        if (offset < 0 || offset > bytes.Length - 2) throw new InvalidDataException("Truncated PE image.");
        return BitConverter.ToUInt16(bytes, offset);
    }

    private static uint U32(byte[] bytes, int offset)
    {
        if (offset < 0 || offset > bytes.Length - 4) throw new InvalidDataException("Truncated PE image.");
        return BitConverter.ToUInt32(bytes, offset);
    }

    private static byte[] ReadRemote(IntPtr process, IntPtr address, int count)
    {
        byte[] bytes = new byte[count];
        UIntPtr read;
        if (!ReadProcessMemory(process, address, bytes, new UIntPtr((uint)count), out read) ||
            read.ToUInt64() != (ulong)count)
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not read the resident PE image");
        return bytes;
    }

    private static PeHeaders ParseHeaders(byte[] bytes)
    {
        if (bytes.Length < 0x100 || U16(bytes, 0) != 0x5a4d)
            throw new InvalidDataException("The image has no valid DOS header.");
        int pe = checked((int)U32(bytes, 0x3c));
        if (pe < 0x40 || pe > bytes.Length - 24 || U32(bytes, pe) != 0x00004550)
            throw new InvalidDataException("The image has no valid PE header.");
        ushort sections = U16(bytes, pe + 6);
        ushort optionalSize = U16(bytes, pe + 20);
        int optional = checked(pe + 24);
        int sectionOffset = checked(optional + optionalSize);
        if (sections == 0 || sections > 96 || sectionOffset > bytes.Length - (sections * 40))
            throw new InvalidDataException("The image has an invalid section table.");
        ushort magic = U16(bytes, optional);
        int directoryBase, directoryCountOffset;
        if (magic == 0x20b) { directoryBase = optional + 112; directoryCountOffset = optional + 108; }
        else if (magic == 0x10b) { directoryBase = optional + 96; directoryCountOffset = optional + 92; }
        else throw new InvalidDataException("The image has an unsupported optional header.");
        uint directoryCount = U32(bytes, directoryCountOffset);
        uint debugRva = 0, debugSize = 0;
        if (directoryCount > 6 && directoryBase + 56 <= optional + optionalSize)
        {
            debugRva = U32(bytes, directoryBase + 48);
            debugSize = U32(bytes, directoryBase + 52);
        }
        return new PeHeaders {
            OptionalOffset = optional, SectionOffset = sectionOffset, SectionCount = sections,
            TimeDateStamp = U32(bytes, pe + 8), SizeOfImage = U32(bytes, optional + 56),
            Checksum = U32(bytes, optional + 64), DebugRva = debugRva, DebugSize = debugSize
        };
    }

    private static int RvaToFileOffset(byte[] bytes, PeHeaders headers, uint rva)
    {
        uint sizeOfHeaders = U32(bytes, headers.OptionalOffset + 60);
        if (rva < sizeOfHeaders) return checked((int)rva);
        for (int index = 0; index < headers.SectionCount; index++)
        {
            int section = headers.SectionOffset + index * 40;
            uint virtualSize = U32(bytes, section + 8);
            uint virtualAddress = U32(bytes, section + 12);
            uint rawSize = U32(bytes, section + 16);
            uint rawOffset = U32(bytes, section + 20);
            uint extent = Math.Max(virtualSize, rawSize);
            if (rva >= virtualAddress && (ulong)rva < (ulong)virtualAddress + extent)
                return checked((int)(rawOffset + (rva - virtualAddress)));
        }
        throw new InvalidDataException("A PE data-directory RVA does not map to a file section.");
    }

    private static string Identity(uint stamp, uint sizeOfImage, uint checksum, byte[] codeView)
    {
        if (codeView == null || codeView.Length < 24 || U32(codeView, 0) != 0x53445352)
            throw new InvalidDataException("The image has no strong RSDS build identity; refusing path-only validation.");
        byte[] guidBytes = new byte[16];
        Buffer.BlockCopy(codeView, 4, guidBytes, 0, 16);
        Guid guid = new Guid(guidBytes);
        uint age = U32(codeView, 20);
        if (guid == Guid.Empty || age == 0)
            throw new InvalidDataException("The image has an invalid RSDS build identity.");
        return String.Format(CultureInfo.InvariantCulture,
            "timestamp={0:x8};size={1:x8};checksum={2:x8};rsds={3:N};age={4}",
            stamp, sizeOfImage, checksum, guid, age);
    }

    public static string FileImageIdentity(string path)
    {
        byte[] bytes;
        using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
        {
            if (stream.Length <= 0 || stream.Length > Int32.MaxValue)
                throw new InvalidDataException("The staged PE image has an invalid size.");
            bytes = new byte[(int)stream.Length];
            int offset = 0;
            while (offset < bytes.Length)
            {
                int read = stream.Read(bytes, offset, bytes.Length - offset);
                if (read == 0) throw new EndOfStreamException("The staged PE image changed while it was read.");
                offset += read;
            }
        }
        PeHeaders headers = ParseHeaders(bytes);
        if (headers.DebugRva == 0 || headers.DebugSize < 28 || headers.DebugSize > 0x10000)
            throw new InvalidDataException("The staged image has no usable debug directory.");
        int debugOffset = RvaToFileOffset(bytes, headers, headers.DebugRva);
        int debugCount = checked((int)(headers.DebugSize / 28));
        for (int index = 0; index < debugCount; index++)
        {
            int entry = checked(debugOffset + index * 28);
            if (entry > bytes.Length - 28) break;
            if (U32(bytes, entry + 12) != 2) continue;
            uint dataSize = U32(bytes, entry + 16);
            uint rawOffset = U32(bytes, entry + 24);
            if (dataSize < 24 || rawOffset > bytes.Length - 24) continue;
            byte[] codeView = new byte[24];
            Buffer.BlockCopy(bytes, checked((int)rawOffset), codeView, 0, 24);
            return Identity(headers.TimeDateStamp, headers.SizeOfImage, headers.Checksum, codeView);
        }
        throw new InvalidDataException("The staged image has no RSDS CodeView record.");
    }

    public static string LoadedImageIdentity(uint processId, IntPtr baseAddress)
    {
        const uint ProcessQueryInformation = 0x0400;
        const uint ProcessVmRead = 0x0010;
        IntPtr process = OpenProcess(ProcessQueryInformation | ProcessVmRead, false, processId);
        if (process == IntPtr.Zero)
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not open the resident product process");
        try
        {
            byte[] initial = ReadRemote(process, baseAddress, 0x1000);
            int pe = checked((int)U32(initial, 0x3c));
            int required = checked(pe + 24 + U16(initial, pe + 20) + U16(initial, pe + 6) * 40);
            byte[] headers = required <= initial.Length ? initial : ReadRemote(process, baseAddress, required);
            PeHeaders parsed = ParseHeaders(headers);
            if (parsed.DebugRva == 0 || parsed.DebugSize < 28 || parsed.DebugSize > 0x10000)
                throw new InvalidDataException("The resident image has no usable debug directory.");
            byte[] debug = ReadRemote(process, new IntPtr(baseAddress.ToInt64() + parsed.DebugRva),
                checked((int)parsed.DebugSize));
            for (int entry = 0; entry <= debug.Length - 28; entry += 28)
            {
                if (U32(debug, entry + 12) != 2) continue;
                uint dataSize = U32(debug, entry + 16);
                uint dataRva = U32(debug, entry + 20);
                if (dataSize < 24 || dataRva == 0) continue;
                byte[] codeView = ReadRemote(process, new IntPtr(baseAddress.ToInt64() + dataRva), 24);
                return Identity(parsed.TimeDateStamp, parsed.SizeOfImage, parsed.Checksum, codeView);
            }
            throw new InvalidDataException("The resident image has no RSDS CodeView record.");
        }
        finally { CloseHandle(process); }
    }

    public static string ProcessLogonId(uint processId)
    {
        const uint ProcessQueryLimitedInformation = 0x1000;
        const uint TokenQuery = 0x0008;
        const int TokenStatistics = 10;
        IntPtr process = OpenProcess(ProcessQueryLimitedInformation, false, processId);
        if (process == IntPtr.Zero)
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not open the process for logon identity");
        try
        {
            IntPtr token;
            if (!OpenProcessToken(process, TokenQuery, out token))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "OpenProcessToken failed");
            try
            {
                int length;
                GetTokenInformation(token, TokenStatistics, IntPtr.Zero, 0, out length);
                if (length < Marshal.SizeOf(typeof(TOKEN_STATISTICS)))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "GetTokenInformation size query failed");
                IntPtr buffer = Marshal.AllocHGlobal(length);
                try
                {
                    if (!GetTokenInformation(token, TokenStatistics, buffer, length, out length))
                        throw new Win32Exception(Marshal.GetLastWin32Error(), "GetTokenInformation failed");
                    TOKEN_STATISTICS stats = (TOKEN_STATISTICS)Marshal.PtrToStructure(buffer, typeof(TOKEN_STATISTICS));
                    return String.Format(CultureInfo.InvariantCulture, "{0:x8}:{1:x8}",
                        unchecked((uint)stats.AuthenticationId.HighPart), stats.AuthenticationId.LowPart);
                }
                finally { Marshal.FreeHGlobal(buffer); }
            }
            finally { CloseHandle(token); }
        }
        finally { CloseHandle(process); }
    }
}
'@
}

function Get-A4SFileImageIdentity {
    param([Parameter(Mandatory)][string] $Path)
    [A4SBinaryIdentityNative]::FileImageIdentity([IO.Path]::GetFullPath($Path))
}

function Get-A4SLoadedImageIdentity {
    param(
        [Parameter(Mandatory)][uint32] $ProcessId,
        [Parameter(Mandatory)][IntPtr] $BaseAddress
    )
    [A4SBinaryIdentityNative]::LoadedImageIdentity($ProcessId, $BaseAddress)
}

function Get-A4SProcessLogonId {
    param([Parameter(Mandatory)][uint32] $ProcessId)
    [A4SBinaryIdentityNative]::ProcessLogonId($ProcessId)
}

function Get-A4SInstalledActiveSlot {
    [CmdletBinding()]
    param()

    $stateKey = 'HKCU:\Software\A4SMenu'
    $activeSlotValue = Get-ItemPropertyValue -LiteralPath $stateKey -Name ActiveSlot -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace([string]$activeSlotValue)) {
        throw 'HKCU\Software\A4SMenu\ActiveSlot is empty.'
    }

    $expandedSlot = [Environment]::ExpandEnvironmentVariables([string]$activeSlotValue)
    $activeSlot = [IO.Path]::GetFullPath($expandedSlot).TrimEnd(
        [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $installRoot = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'A4SMenu')).TrimEnd(
        [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $versionsRoot = [IO.Path]::GetFullPath((Join-Path $installRoot 'versions')).TrimEnd(
        [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    if (-not [StringComparer]::OrdinalIgnoreCase.Equals([IO.Path]::GetDirectoryName($activeSlot), $versionsRoot)) {
        throw "Registered ActiveSlot '$activeSlot' is not one direct child of the canonical versions directory '$versionsRoot'."
    }
    foreach ($directory in @($installRoot, $versionsRoot, $activeSlot)) {
        $item = Get-Item -LiteralPath $directory -Force -ErrorAction Stop
        if (-not $item.PSIsContainer) { throw "Expected an installed product directory: '$directory'." }
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Installed product qualification refuses a reparse-point directory: '$directory'."
        }
    }
    foreach ($name in @('A4SMenuHost.exe', 'A4SMenu.dll')) {
        $path = Join-Path $activeSlot $name
        $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Installed product qualification requires a regular file: '$path'."
        }
    }
    $activeSlot
}

function Get-A4SProductDirectoryRegistration {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $ProductDirectory)

    $directory = [IO.Path]::GetFullPath($ProductDirectory).TrimEnd(
        [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $versionsRoot = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'A4SMenu\versions')).TrimEnd(
        [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    if (-not [StringComparer]::OrdinalIgnoreCase.Equals([IO.Path]::GetDirectoryName($directory), $versionsRoot)) {
        return [pscustomobject][ordered]@{ kind = 'development-or-explicit'; activeSlot = $null }
    }
    $activeSlot = Get-A4SInstalledActiveSlot
    if (-not [StringComparer]::OrdinalIgnoreCase.Equals($directory, $activeSlot)) {
        throw "Selected installed product directory '$directory' is not the registry ActiveSlot '$activeSlot'."
    }
    [pscustomobject][ordered]@{ kind = 'installed-active-slot'; activeSlot = $activeSlot }
}

function Enter-A4SQualificationAutomationLock {
    [CmdletBinding()]
    param()

    # All product qualification tools use the same session-local mutex. This
    # prevents a performance probe or scenario run from injecting extra menu
    # cycles into a custom-provider trace (and prevents two cleanup paths from
    # racing over the same resident menu). Local\ already separates terminal
    # sessions; retaining the numeric session in the name makes that scope
    # explicit in diagnostics.
    $sessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
    $name = "Local\A4SMenu.QualificationAutomation.v1.$sessionId"
    $mutex = [Threading.Mutex]::new($false, $name)
    $held = $false
    try {
        try { $held = $mutex.WaitOne([TimeSpan]::Zero) }
        catch [Threading.AbandonedMutexException] { $held = $true }
        if (-not $held) {
            throw "Another A4S menu qualification tool already owns '$name'. Wait for it to finish so trace and scenario evidence cannot overlap."
        }
        return $mutex
    } catch {
        $mutex.Dispose()
        throw
    }
}

function Exit-A4SQualificationAutomationLock {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Threading.Mutex] $Mutex)

    try { $Mutex.ReleaseMutex() }
    finally { $Mutex.Dispose() }
}

Export-ModuleMember -Function Get-A4SFileImageIdentity, Get-A4SLoadedImageIdentity, Get-A4SProcessLogonId, `
    Get-A4SInstalledActiveSlot, Get-A4SProductDirectoryRegistration, `
    Enter-A4SQualificationAutomationLock, Exit-A4SQualificationAutomationLock
