$ErrorActionPreference = 'Stop'
if (-not ('VibeReplay.ControllerWindow' -as [type])) {
    $assembly = Join-Path $PSScriptRoot 'VibeReplay.Shell.dll'
    if (Test-Path -LiteralPath $assembly -PathType Leaf) {
        Add-Type -Path $assembly
    } else {
        Add-Type -AssemblyName PresentationFramework, System.Windows.Forms
        Add-Type -Path (Join-Path $PSScriptRoot 'PlayerShell.cs') -ReferencedAssemblies @(
            'PresentationFramework', 'PresentationCore', 'WindowsBase', 'System.Xaml',
            'System.Windows.Forms', 'System.Drawing', 'System', 'System.Core', 'System.Web.Extensions'
        )
    }
}
