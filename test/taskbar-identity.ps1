param(
    [string]$ApplicationRoot = (Split-Path $PSScriptRoot -Parent),
    [string]$EvidenceRoot = (Join-Path (Split-Path $PSScriptRoot -Parent) '.build\taskbar-identity')
)

$ErrorActionPreference = 'Stop'
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Run with powershell.exe -NoProfile -STA.' }
if (-not [Environment]::Is64BitProcess) { throw 'Run with x64 Windows PowerShell, matching the installed app.' }
[IO.Directory]::CreateDirectory($EvidenceRoot) | Out-Null
$EvidenceRoot = [IO.Path]::GetFullPath($EvidenceRoot)
$assertions = 0
function Assert-Equal($Actual, $Expected, [string]$Label) {
    if ($Actual -cne $Expected) { throw ($Label + ': expected ' + $Expected + ', got ' + $Actual) }
    $script:assertions++
}
Add-Type -AssemblyName PresentationFramework
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class TaskbarIdentityProbe
{
    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    public struct Key { public Guid Format; public uint Id; }
    [StructLayout(LayoutKind.Explicit, Size = 24)]
    public struct Variant {
        [FieldOffset(0)] public ushort Type;
        [FieldOffset(8)] public IntPtr Value;
    }
    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface Store {
        [PreserveSig] int GetCount(out uint count);
        [PreserveSig] int GetAt(uint index, out Key key);
        [PreserveSig] int GetValue(ref Key key, out Variant value);
        [PreserveSig] int SetValue(ref Key key, ref Variant value);
        [PreserveSig] int Commit();
    }
    [DllImport("shell32.dll")] private static extern int SHGetPropertyStoreForWindow(IntPtr window, ref Guid iid, out Store store);
    [DllImport("ole32.dll")] private static extern int PropVariantClear(ref Variant value);
    [DllImport("shell32.dll")] private static extern int GetCurrentProcessExplicitAppUserModelID(out IntPtr appId);
    [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CommandLineToArgvW(string command, out int count);
    [DllImport("kernel32.dll")] private static extern IntPtr LocalFree(IntPtr memory);
    public static string ProcessId() {
        IntPtr value;
        int result = GetCurrentProcessExplicitAppUserModelID(out value);
        if (result == unchecked((int)0x80004005)) return null;
        Marshal.ThrowExceptionForHR(result);
        try { return Marshal.PtrToStringUni(value); }
        finally { Marshal.FreeCoTaskMem(value); }
    }
    public static string Read(IntPtr window, uint id) {
        Guid iid = typeof(Store).GUID;
        Store store;
        Marshal.ThrowExceptionForHR(SHGetPropertyStoreForWindow(window, ref iid, out store));
        try {
            var key = new Key { Format = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"), Id = id };
            Variant value;
            Marshal.ThrowExceptionForHR(store.GetValue(ref key, out value));
            try {
                if (value.Type == 0) return null;
                if (value.Type != 31) throw new InvalidOperationException("Expected VT_LPWSTR, got " + value.Type);
                return Marshal.PtrToStringUni(value.Value);
            }
            finally { Marshal.ThrowExceptionForHR(PropVariantClear(ref value)); }
        }
        finally { Marshal.ReleaseComObject(store); }
    }
    public static string[] Arguments(string command) {
        int count;
        IntPtr values = CommandLineToArgvW(command, out count);
        if (values == IntPtr.Zero) throw new System.ComponentModel.Win32Exception();
        try {
            var result = new string[count];
            for (int i = 0; i < count; i++) result[i] = Marshal.PtrToStringUni(Marshal.ReadIntPtr(values, i * IntPtr.Size));
            return result;
        }
        finally { LocalFree(values); }
    }
}
'@
$originalId = [TaskbarIdentityProbe]::ProcessId()
Add-Type -Path (Join-Path $ApplicationRoot 'PlayerTaskbarIdentity.cs')
Assert-Equal ([TaskbarIdentityProbe]::ProcessId()) $originalId 'Loading helper does not change source-run identity'
$launcher = Join-Path $ApplicationRoot 'VSCodeDemoPlayer.exe'
if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) { throw 'Supply -ApplicationRoot pointing to a disposable built payload.' }
$window = [Windows.Window]::new()
$window.Title = 'Demo Player taskbar identity - synthetic acceptance'
$window.Width = 360
$window.Height = 100
$window.ShowInTaskbar = $false
try {
    $handle = [Windows.Interop.WindowInteropHelper]::new($window).EnsureHandle()
    Assert-Equal ([TaskbarIdentityProbe]::Read($handle, 5)) $null 'Source-run window has no installed identity'
    Assert-Equal ([TaskbarIdentityProbe]::Read($handle, 2)) $null 'Source-run window has no relaunch override'
    [PlayerTaskbarIdentity]::InitializeProcess()
    Assert-Equal ([TaskbarIdentityProbe]::ProcessId()) 'VSCodeDemoPlayer.Desktop' 'Installed process AppUserModelID readback'
    $InstalledLauncherPath = $launcher
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $ApplicationRoot 'Show-ReplayController.ps1'), [ref]$null, [ref]$null)
    $initialize = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.IfStatementAst] -and
        $node.Clauses[0].Item1.Extent.Text -eq '$InstalledLauncherPath'
    }, $true)
    Assert-Equal ($null -ne $initialize) $true 'Production installed-only window initialization exists'
    & ([scriptblock]::Create($initialize.Clauses[0].Item2.Extent.Text.TrimStart('{').TrimEnd('}')))
    Assert-Equal ($null -ne $window.Icon) $true 'Running controller uses launcher icon'
    $window.Show()
    $properties = [ordered]@{
        appId = [TaskbarIdentityProbe]::Read($handle, 5)
        command = [TaskbarIdentityProbe]::Read($handle, 2)
        displayName = [TaskbarIdentityProbe]::Read($handle, 4)
        icon = [TaskbarIdentityProbe]::Read($handle, 3)
        processAppId = [TaskbarIdentityProbe]::ProcessId()
    }
    Assert-Equal $properties.appId 'VSCodeDemoPlayer.Desktop' 'Running HWND AppUserModelID readback'
    Assert-Equal $properties.displayName 'VS Code Demo Player' 'Relaunch display name readback'
    Assert-Equal $properties.icon ($launcher + ',0') 'Relaunch icon readback'
    $arguments = [TaskbarIdentityProbe]::Arguments($properties.command)
    $expected = @($launcher, '-TaskbarRelaunch')
    Assert-Equal $arguments.Count $expected.Count 'Relaunch argument count'
    for ($i = 0; $i -lt $expected.Count; $i++) { Assert-Equal $arguments[$i] $expected[$i] ('Relaunch argument ' + $i) }
    Assert-Equal ($properties.command.Length -lt 260) $true 'Relaunch command fits the native MAX_PATH limit'
    try {
        [PlayerTaskbarIdentity]::InitializeWindow([IntPtr]::Zero, $launcher)
        throw 'Expected an invalid HWND failure.'
    } catch {
        if ($_.Exception.Message -eq 'Expected an invalid HWND failure.') { throw }
        $assertions++
    }
    try {
        [PlayerTaskbarIdentity]::RelaunchCommand((Join-Path $EvidenceRoot 'missing.exe'))
        throw 'Expected a missing launcher failure.'
    } catch {
        if ($_.Exception.Message -notmatch 'taskbar launcher is missing') { throw }
        $assertions++
    }
    $closing = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
        $node.Expression.Extent.Text -eq '$window' -and $node.Member.Value -eq 'Add_Closing'
    }, $true)
    Assert-Equal ($null -ne $closing) $true 'Production close handler exists'
    $close = $closing.Arguments[0].ScriptBlock.GetScriptBlock()
    function Request-Stop { $script:stopRequested = $true }
    $ReplayProcessId = 42
    $script:closeAllowed = $false
    $eventArgs = [ComponentModel.CancelEventArgs]::new()
    & $close $window $eventArgs
    Assert-Equal $eventArgs.Cancel $true 'Active replay still defers controller close'
    Assert-Equal $script:stopRequested $true 'Deferred close retains scoped stop behavior'
    Assert-Equal ([TaskbarIdentityProbe]::Read($handle, 5)) $properties.appId 'Cancelled close preserves taskbar identity'
    $script:closeAllowed = $true
    $eventArgs = [ComponentModel.CancelEventArgs]::new()
    & $close $window $eventArgs
    for ($id = 2; $id -le 5; $id++) {
        Assert-Equal ([TaskbarIdentityProbe]::Read($handle, $id)) $null ('Actual close clears native property ' + $id)
    }
    $properties | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $EvidenceRoot 'window-properties.json') -Encoding UTF8
    Write-Output ("TASKBAR IDENTITY PASSED: $assertions assertions; native process/HWND readback, production window initialization/close cleanup, cancelled replay close, relaunch arguments, name/icon, source-run isolation, explicit API/path failures. No pins, shortcuts, registry, installed app, library or editor were modified.")
} finally {
    try { if ($handle) { [PlayerTaskbarIdentity]::ClearWindow($handle) } }
    finally { $window.Close() }
}
