$p = 'C:\ProgramData\CRJ\telas'
if (Test-Path 'C:\ProgramData\CRJ\defeito.txt') { exit }
$c = Get-Content "$p\config.json" -Raw | ConvertFrom-Json
if (-not $c.fundo) { exit }
$imgs = @(Get-ChildItem $p -File | Where-Object { $_.Extension -match '^\.(jpe?g|png|bmp)$' } | Sort-Object Name)
if (-not $imgs) { exit }
$seg = [int]$c.intervaloSeg
$cs = @'
using System; using System.Runtime.InteropServices;
[StructLayout(LayoutKind.Sequential)] public struct CRJRect { public int L, T, R, B; }
[ComImport, Guid("B92B56A9-8B55-4E14-9A89-0199BBB6F93B"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface ICRJDesktopWallpaper {
    void SetWallpaper([MarshalAs(UnmanagedType.LPWStr)] string monitorID, [MarshalAs(UnmanagedType.LPWStr)] string wallpaper);
    [return: MarshalAs(UnmanagedType.LPWStr)] string GetWallpaper([MarshalAs(UnmanagedType.LPWStr)] string monitorID);
    [return: MarshalAs(UnmanagedType.LPWStr)] string GetMonitorDevicePathAt(uint monitorIndex);
    uint GetMonitorDevicePathCount();
    void GetMonitorRECT([MarshalAs(UnmanagedType.LPWStr)] string monitorID, out CRJRect r);
    void SetBackgroundColor(uint color);
    uint GetBackgroundColor();
    void SetPosition(int position);
    int GetPosition();
    void SetSlideshow(IntPtr items);
    IntPtr GetSlideshow();
    void SetSlideshowOptions(int options, uint slideshowTick);
}
public static class CRJFundo {
    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)] static extern void SHCreateItemFromParsingName(string path, IntPtr pbc, ref Guid riid, out IntPtr ppv);
    [DllImport("shell32.dll", PreserveSig = false)] static extern void SHCreateShellItemArrayFromShellItem(IntPtr psi, ref Guid riid, out IntPtr ppv);
    static ICRJDesktopWallpaper Obj() { return (ICRJDesktopWallpaper)Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("C2CF3110-460E-4fc1-B9D0-8A1C0C9CC4BD"))); }
    public static void Unica(string img) { var w = Obj(); w.SetPosition(4); w.SetWallpaper(null, img); }
    public static void Slides(string pasta, uint ms) {
        var w = Obj(); w.SetPosition(4);
        Guid iItem = new Guid("43826d1e-e718-42ee-bc55-a1e261c37bfe"), iArr = new Guid("b63ea76d-1f85-456f-a19c-48159efa858b");
        IntPtr item, arr; SHCreateItemFromParsingName(pasta, IntPtr.Zero, ref iItem, out item);
        SHCreateShellItemArrayFromShellItem(item, ref iArr, out arr);
        w.SetSlideshow(arr); w.SetSlideshowOptions(0, ms);
        Marshal.Release(arr); Marshal.Release(item);
    }
}
'@
Add-Type -TypeDefinition $cs
if ($imgs.Count -gt 1 -and $seg -gt 0) {
    # slide nativo do Windows: transicao esmaecida entre as fotos
    [CRJFundo]::Slides($p, [uint32]($seg * 1000))
} else {
    [CRJFundo]::Unica($imgs[0].FullName)
}