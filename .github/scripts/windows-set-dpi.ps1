# Change the primary display's scaling the way Settings > Display > Scale does,
# so a running per-monitor-aware window receives a real WM_DPICHANGED (TASK-49
# AC3).
#
# Usage: windows-set-dpi.ps1 -Percent <100|125|150|175|200|...>
#        windows-set-dpi.ps1 -Query
#
# Windows has no documented API for this. Settings calls
# DisplayConfigSetDeviceInfo with the undocumented device-info types -3 (get
# the source's DPI scale, as steps relative to the recommended one) and -4 (set
# it); this is the same call, through the active source QueryDisplayConfig
# reports. Prints "dpi <current>% (recommended <r>%, range <min>%..<max>%)".
param(
  [int]$Percent = 0,
  [switch]$Query
)
$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class ConduitDpi {
    [StructLayout(LayoutKind.Sequential)]
    public struct LUID { public uint Low; public int High; }

    [StructLayout(LayoutKind.Sequential)]
    public struct Header { public int Type; public uint Size; public LUID Adapter; public uint Id; }

    [StructLayout(LayoutKind.Sequential)]
    public struct GetScale { public Header Header; public int Min; public int Cur; public int Max; }

    [StructLayout(LayoutKind.Sequential)]
    public struct SetScale { public Header Header; public int Rel; }

    [DllImport("user32.dll")]
    public static extern int GetDisplayConfigBufferSizes(uint flags, out uint paths, out uint modes);
    [DllImport("user32.dll")]
    public static extern int QueryDisplayConfig(uint flags, ref uint paths, byte[] pathArray, ref uint modes, byte[] modeArray, IntPtr topology);
    [DllImport("user32.dll")]
    public static extern int DisplayConfigGetDeviceInfo(ref GetScale request);
    [DllImport("user32.dll")]
    public static extern int DisplayConfigSetDeviceInfo(ref SetScale request);

    public static readonly int[] Steps = { 100, 125, 150, 175, 200, 225, 250, 300, 350, 400, 450, 500 };

    // The first active path's source: DISPLAYCONFIG_PATH_INFO is 72 bytes and
    // starts with the source's LUID adapter id (8 bytes) and source id (4).
    public static Header Source() {
        uint paths, modes;
        int rc = GetDisplayConfigBufferSizes(2, out paths, out modes);
        if (rc != 0) throw new Exception("GetDisplayConfigBufferSizes " + rc);
        byte[] pathArray = new byte[paths * 72];
        byte[] modeArray = new byte[modes * 64];
        rc = QueryDisplayConfig(2, ref paths, pathArray, ref modes, modeArray, IntPtr.Zero);
        if (rc != 0) throw new Exception("QueryDisplayConfig " + rc);
        if (paths == 0) throw new Exception("no active display path");
        Header h = new Header();
        h.Adapter.Low = BitConverter.ToUInt32(pathArray, 0);
        h.Adapter.High = BitConverter.ToInt32(pathArray, 4);
        h.Id = BitConverter.ToUInt32(pathArray, 8);
        return h;
    }

    public static GetScale Get() {
        GetScale g = new GetScale();
        g.Header = Source();
        g.Header.Type = -3;
        g.Header.Size = (uint)Marshal.SizeOf(typeof(GetScale));
        int rc = DisplayConfigGetDeviceInfo(ref g);
        if (rc != 0) throw new Exception("DisplayConfigGetDeviceInfo " + rc);
        return g;
    }

    public static int Recommended(GetScale g) { return Math.Abs(g.Min); }

    public static string Describe(GetScale g) {
        int r = Recommended(g);
        int cur = Math.Min(Math.Max(r + g.Cur, 0), Steps.Length - 1);
        int lo = Math.Min(Math.Max(r + g.Min, 0), Steps.Length - 1);
        int hi = Math.Min(Math.Max(r + g.Max, 0), Steps.Length - 1);
        return "dpi " + Steps[cur] + "% (recommended " + Steps[r] + "%, range " + Steps[lo] + "%.." + Steps[hi] + "%)";
    }

    public static void Set(int percent) {
        GetScale g = Get();
        int target = Array.IndexOf(Steps, percent);
        if (target < 0) throw new Exception("not a Windows scale step: " + percent);
        int rel = target - Recommended(g);
        if (rel < g.Min || rel > g.Max) throw new Exception(percent + "% is outside this display's range: " + Describe(g));
        SetScale s = new SetScale();
        s.Header = g.Header;
        s.Header.Type = -4;
        s.Header.Size = (uint)Marshal.SizeOf(typeof(SetScale));
        s.Rel = rel;
        int rc = DisplayConfigSetDeviceInfo(ref s);
        if (rc != 0) throw new Exception("DisplayConfigSetDeviceInfo " + rc);
    }
}
'@

if ($Percent -gt 0) {
  [ConduitDpi]::Set($Percent)
  Start-Sleep -Milliseconds 500
}
Write-Output ([ConduitDpi]::Describe([ConduitDpi]::Get()))
