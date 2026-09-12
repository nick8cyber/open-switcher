$src = @'
using System;
using System.Runtime.InteropServices;
public static class K {
  [DllImport("user32.dll")]
  public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  public static void ShiftPause() {
    keybd_event(0x10, 0, 0, UIntPtr.Zero);          // Shift down
    System.Threading.Thread.Sleep(60);
    keybd_event(0x13, 0x46, 0, UIntPtr.Zero);       // VK_PAUSE down
    System.Threading.Thread.Sleep(40);
    keybd_event(0x13, 0x46, 2, UIntPtr.Zero);       // VK_PAUSE up
    System.Threading.Thread.Sleep(60);
    keybd_event(0x10, 0, 2, UIntPtr.Zero);          // Shift up
  }
}
'@
Add-Type -TypeDefinition $src
[K]::ShiftPause()
"shift+pause sent"
