using System;
using System.IO;
using System.Runtime.InteropServices;

public static class PlayerTaskbarIdentity
{
    public const string AppId = "VSCodeDemoPlayer.Desktop";
    private static readonly Guid AppModelFormat = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    private struct PropertyKey
    {
        public Guid Format;
        public uint Id;
        public PropertyKey(uint id) { Format = AppModelFormat; Id = id; }
    }

    [StructLayout(LayoutKind.Explicit, Size = 24)]
    private struct PropVariant
    {
        [FieldOffset(0)] public ushort Type;
        [FieldOffset(8)] public IntPtr Value;
    }

    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IPropertyStore
    {
        [PreserveSig] int GetCount(out uint count);
        [PreserveSig] int GetAt(uint index, out PropertyKey key);
        [PreserveSig] int GetValue(ref PropertyKey key, out PropVariant value);
        [PreserveSig] int SetValue(ref PropertyKey key, ref PropVariant value);
        [PreserveSig] int Commit();
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = true)]
    private static extern int SetCurrentProcessExplicitAppUserModelID(string appId);

    [DllImport("shell32.dll", PreserveSig = true)]
    private static extern int SHGetPropertyStoreForWindow(IntPtr window, ref Guid iid, out IPropertyStore store);

    public static void InitializeProcess()
    {
        Marshal.ThrowExceptionForHR(SetCurrentProcessExplicitAppUserModelID(AppId));
    }

    public static string RelaunchCommand(string launcher)
    {
        if (!File.Exists(launcher)) throw new FileNotFoundException("The taskbar launcher is missing. Reinstall VS Code Demo Player.", launcher);
        string command = "\"" + Path.GetFullPath(launcher) + "\" -TaskbarRelaunch";
        if (command.Length >= 260) throw new InvalidOperationException("The installation path is too long for Windows taskbar relaunch. Reinstall VS Code Demo Player in a shorter path.");
        return command;
    }

    private static void SetString(IPropertyStore store, uint id, string text)
    {
        var key = new PropertyKey(id);
        var value = text == null ? new PropVariant() : new PropVariant { Type = 31, Value = Marshal.StringToCoTaskMemUni(text) };
        try
        {
            int result = store.SetValue(ref key, ref value);
            if (result < 0) throw new COMException("Could not set Windows taskbar property " + id + ".", result);
            if (result != 0) throw new InvalidOperationException("Windows truncated taskbar property " + id + ".");
        }
        finally { Marshal.FreeCoTaskMem(value.Value); }
    }

    public static void InitializeWindow(IntPtr window, string launcher)
    {
        string command = RelaunchCommand(launcher);
        Guid iid = typeof(IPropertyStore).GUID;
        IPropertyStore store;
        Marshal.ThrowExceptionForHR(SHGetPropertyStoreForWindow(window, ref iid, out store));
        try
        {
            // Set relaunch details before the explicit ID, as required by the Shell.
            SetString(store, 2, command);
            SetString(store, 3, Path.GetFullPath(launcher) + ",0");
            SetString(store, 4, "VS Code Demo Player");
            SetString(store, 5, AppId);
        }
        finally { Marshal.ReleaseComObject(store); }
    }

    public static void ClearWindow(IntPtr window)
    {
        Guid iid = typeof(IPropertyStore).GUID;
        IPropertyStore store;
        Marshal.ThrowExceptionForHR(SHGetPropertyStoreForWindow(window, ref iid, out store));
        try
        {
            for (uint id = 2; id <= 5; id++) SetString(store, id, null);
        }
        finally { Marshal.ReleaseComObject(store); }
    }
}
