using System.Runtime.InteropServices;
// ReSharper disable IdentifierTypo
// ReSharper disable InconsistentNaming
// ReSharper disable CommentTypo
// ReSharper disable StringLiteralTypo

namespace ActiveBorder;

/**
 * Raw Win32 / GDI / DWM interop. There is no policy in here; it is a thin,
 * literal translation of the platform headers.
 */
internal static class NativeMethods
{
	// ------------------------------------------------------------------
	// Window styles
	// ------------------------------------------------------------------
	internal const int WS_POPUP = unchecked((int)0x80000000);
	internal const int WS_EX_TOPMOST = 0x00000008;
	internal const int WS_EX_TRANSPARENT = 0x00000020;
	internal const int WS_EX_TOOLWINDOW = 0x00000080;
	internal const int WS_EX_LAYERED = 0x00080000;
	internal const int WS_EX_NOACTIVATE = 0x08000000;

	internal const int GWL_EXSTYLE = -20;

	// ------------------------------------------------------------------
	// Messages
	// ------------------------------------------------------------------
	internal const int WM_DESTROY = 0x0002;
	internal const int WM_CLOSE = 0x0010;
	internal const int WM_ERASEBKGND = 0x0014;
	internal const int WM_MOUSEACTIVATE = 0x0021;
	internal const int WM_DISPLAYCHANGE = 0x007E;
	internal const int WM_NCHITTEST = 0x0084;
	internal const int WM_TIMER = 0x0113;

	internal const int WM_COMMAND = 0x0111;
	internal const int WM_NULL = 0x0000;
	internal const int WM_RBUTTONUP = 0x0205;
	internal const int WM_APP = 0x8000;

	internal const int MA_NOACTIVATE = 3;
	internal const int HTTRANSPARENT = -1;

	// ------------------------------------------------------------------
	// Notification area (tray)
	// ------------------------------------------------------------------
	internal const uint NIM_ADD = 0x00000000;
	internal const uint NIM_DELETE = 0x00000002;

	internal const uint NIF_MESSAGE = 0x00000001;
	internal const uint NIF_ICON = 0x00000002;
	internal const uint NIF_TIP = 0x00000004;

	internal const int SM_CXSMICON = 49;
	internal const int SM_CYSMICON = 50;

	// ------------------------------------------------------------------
	// Menus
	// ------------------------------------------------------------------
	internal const uint MF_STRING = 0x00000000;

	internal const uint TPM_LEFTALIGN = 0x0000;
	internal const uint TPM_RIGHTBUTTON = 0x0002;

	internal const uint MB_ICONERROR = 0x00000010;

	// ------------------------------------------------------------------
	// SetWindowPos / ShowWindow
	// ------------------------------------------------------------------
	internal const uint SWP_NOSIZE = 0x0001;
	internal const uint SWP_NOMOVE = 0x0002;
	internal const uint SWP_NOACTIVATE = 0x0010;
	internal const uint SWP_NOOWNERZORDER = 0x0200;
	internal const uint SWP_NOSENDCHANGING = 0x0400;

	internal static readonly IntPtr HWND_TOP = IntPtr.Zero;
	internal static readonly IntPtr HWND_TOPMOST = new(-1);
	internal static readonly IntPtr HWND_NOTOPMOST = new(-2);

	internal const int SW_HIDE = 0;
	internal const int SW_SHOWNOACTIVATE = 4;

	internal const uint GW_HWNDPREV = 3;

	internal const int SM_CXVIRTUALSCREEN = 78;
	internal const int SM_CYVIRTUALSCREEN = 79;

	// ------------------------------------------------------------------
	// WinEvents
	// ------------------------------------------------------------------
	internal const uint WINEVENT_OUTOFCONTEXT = 0x0000;
	internal const uint WINEVENT_SKIPOWNPROCESS = 0x0002;

	internal const uint EVENT_SYSTEM_FOREGROUND = 0x0003;
	internal const uint EVENT_SYSTEM_MOVESIZESTART = 0x000A;
	internal const uint EVENT_SYSTEM_MOVESIZEEND = 0x000B;
	internal const uint EVENT_SYSTEM_MINIMIZESTART = 0x0016;
	internal const uint EVENT_SYSTEM_MINIMIZEEND = 0x0017;

	internal const uint EVENT_OBJECT_DESTROY = 0x8001;
	internal const uint EVENT_OBJECT_SHOW = 0x8002;
	internal const uint EVENT_OBJECT_HIDE = 0x8003;
	internal const uint EVENT_OBJECT_LOCATIONCHANGE = 0x800B;

	internal const int OBJID_WINDOW = 0;
	internal const int CHILDID_SELF = 0;

	// ------------------------------------------------------------------
	// DWM
	// ------------------------------------------------------------------
	internal const int DWMWA_EXTENDED_FRAME_BOUNDS = 9;
	internal const int DWMWA_CLOAKED = 14;

	// ------------------------------------------------------------------
	// Layered windows / GDI
	// ------------------------------------------------------------------
	internal const int ULW_ALPHA = 0x00000002;
	internal const byte AC_SRC_OVER = 0x00;
	internal const byte AC_SRC_ALPHA = 0x01;

	internal const int BI_RGB = 0;
	internal const uint DIB_RGB_COLORS = 0;

	// DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2
	internal static readonly IntPtr DpiAwarenessContextPerMonitorAwareV2 = new(-4);

	// ------------------------------------------------------------------
	// Structures
	// ------------------------------------------------------------------
	[StructLayout(LayoutKind.Sequential)]
	internal struct RECT
	{
		public int Left, Top, Right, Bottom;

		public readonly int Width => Right - Left;
		public readonly int Height => Bottom - Top;
		public readonly bool IsEmpty => Right <= Left || Bottom <= Top;

		public readonly bool SameAs(in RECT o) => Left == o.Left && Top == o.Top && Right == o.Right && Bottom == o.Bottom;

		public readonly override string ToString() => Left + "," + Top + " " + Width + "x" + Height;
	}

	[StructLayout(LayoutKind.Sequential)]
	internal struct POINT
	{
		public int X, Y;
		public POINT(int x, int y)
		{
			X = x;
			Y = y;
		}
	}

	[StructLayout(LayoutKind.Sequential)]
	internal struct SIZE
	{
		public int Cx, Cy;
		public SIZE(int cx, int cy)
		{
			Cx = cx;
			Cy = cy;
		}
	}

	[StructLayout(LayoutKind.Sequential, Pack = 1)]
	internal struct BLENDFUNCTION
	{
		public byte BlendOp;
		public byte BlendFlags;
		public byte SourceConstantAlpha;
		public byte AlphaFormat;
	}

	[StructLayout(LayoutKind.Sequential)]
	internal struct MSG
	{
		public IntPtr Hwnd;
		public uint Message;
		public IntPtr WParam;
		public IntPtr LParam;
		public uint Time;
		public POINT Pt;
	}

	[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
	internal struct WNDCLASSEXW
	{
		public uint CbSize;
		public uint Style;
		public IntPtr LpfnWndProc;
		public int CbClsExtra;
		public int CbWndExtra;
		public IntPtr HInstance;
		public IntPtr HIcon;
		public IntPtr HCursor;
		public IntPtr HbrBackground;
		[MarshalAs(UnmanagedType.LPWStr)] public string? LpszMenuName;
		[MarshalAs(UnmanagedType.LPWStr)] public string LpszClassName;
		public IntPtr HIconSm;
	}

	[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
	internal struct NOTIFYICONDATAW
	{
		public uint CbSize;
		public IntPtr HWnd;
		public uint UID;
		public uint UFlags;
		public uint UCallbackMessage;
		public IntPtr HIcon;
		[MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string SzTip;
		public uint DwState;
		public uint DwStateMask;
		[MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string SzInfo;
		public uint UVersion;
		[MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string SzInfoTitle;
		public uint DwInfoFlags;
		public Guid GuidItem;
		public IntPtr HBalloonIcon;
	}

	[StructLayout(LayoutKind.Sequential)]
	internal struct ICONINFO
	{
		public bool FIcon;
		public int XHotspot;
		public int YHotspot;
		public IntPtr HbmMask;
		public IntPtr HbmColor;
	}

	[StructLayout(LayoutKind.Sequential)]
	internal struct BITMAPINFOHEADER
	{
		public uint BiSize;
		public int BiWidth;
		public int BiHeight;
		public ushort BiPlanes;
		public ushort BiBitCount;
		public uint BiCompression;
		public uint BiSizeImage;
		public int BiXPelsPerMeter;
		public int BiYPelsPerMeter;
		public uint BiClrUsed;
		public uint BiClrImportant;
	}

	// ------------------------------------------------------------------
	// Delegates. Any instance handed to Win32 MUST be kept alive by
	// managed code for as long as the OS can call back into it.
	// ------------------------------------------------------------------
	internal delegate IntPtr WndProc(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);

	internal delegate void WinEventProc(IntPtr hWinEventHook, uint eventType, IntPtr hwnd, int idObject, int idChild, uint dwEventThread, uint dwmsEventTime);

	// ------------------------------------------------------------------
	// user32
	// ------------------------------------------------------------------
	[DllImport("user32.dll", SetLastError = true)]
	internal static extern bool SetProcessDpiAwarenessContext(IntPtr value);

	[DllImport("user32.dll")]
	internal static extern bool SetProcessDPIAware();

	[DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
	internal static extern ushort RegisterClassExW(ref WNDCLASSEXW wc);

	[DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
	internal static extern bool UnregisterClassW([MarshalAs(UnmanagedType.LPWStr)] string className, IntPtr hInstance);

	[DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
	internal static extern IntPtr CreateWindowExW(int exStyle, [MarshalAs(UnmanagedType.LPWStr)] string className, [MarshalAs(UnmanagedType.LPWStr)] string? windowName, int style, int x, int y, int width, int height, IntPtr parent, IntPtr menu, IntPtr hInstance, IntPtr param);

	[DllImport("user32.dll", SetLastError = true)]
	internal static extern bool DestroyWindow(IntPtr hwnd);

	[DllImport("user32.dll", CharSet = CharSet.Unicode)]
	internal static extern IntPtr DefWindowProcW(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);

	[DllImport("user32.dll")]
	internal static extern bool ShowWindow(IntPtr hwnd, int cmdShow);

	[DllImport("user32.dll", SetLastError = true)]
	internal static extern bool SetWindowPos(IntPtr hwnd, IntPtr hwndInsertAfter, int x, int y, int cx, int cy, uint flags);

	[DllImport("user32.dll", SetLastError = true)]
	internal static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);

	[DllImport("user32.dll")]
	internal static extern IntPtr GetForegroundWindow();

	[DllImport("user32.dll")]
	internal static extern bool IsWindow(IntPtr hwnd);

	[DllImport("user32.dll")]
	internal static extern bool IsWindowVisible(IntPtr hwnd);

	[DllImport("user32.dll")]
	internal static extern bool IsIconic(IntPtr hwnd);

	[DllImport("user32.dll", CharSet = CharSet.Unicode)]
	internal static extern int GetClassNameW(IntPtr hwnd, char[] buffer, int maxCount);

	[DllImport("user32.dll")]
	internal static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);

	[DllImport("user32.dll")]
	internal static extern IntPtr GetWindow(IntPtr hwnd, uint cmd);

	[DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW", CharSet = CharSet.Unicode)]
	private static extern IntPtr GetWindowLongPtr64(IntPtr hwnd, int index);

	[DllImport("user32.dll", EntryPoint = "GetWindowLongW", CharSet = CharSet.Unicode)]
	private static extern int GetWindowLong32(IntPtr hwnd, int index);

	/** Bitness-agnostic GetWindowLongPtr. */
	internal static IntPtr GetWindowLongPtr(IntPtr hwnd, int index) => IntPtr.Size == 8 ? GetWindowLongPtr64(hwnd, index) : new IntPtr(GetWindowLong32(hwnd, index));

	[DllImport("user32.dll")]
	internal static extern int GetSystemMetrics(int index);

	[DllImport("user32.dll", SetLastError = true)]
	internal static extern IntPtr SetWinEventHook(uint eventMin, uint eventMax, IntPtr hmodWinEventProc, WinEventProc callback, uint idProcess, uint idThread, uint flags);

	[DllImport("user32.dll")]
	internal static extern bool UnhookWinEvent(IntPtr hWinEventHook);

	[DllImport("user32.dll", CharSet = CharSet.Unicode)]
	internal static extern int GetMessageW(out MSG msg, IntPtr hwnd, uint filterMin, uint filterMax);

	[DllImport("user32.dll")]
	internal static extern bool TranslateMessage(ref MSG msg);

	[DllImport("user32.dll", CharSet = CharSet.Unicode)]
	internal static extern IntPtr DispatchMessageW(ref MSG msg);

	[DllImport("user32.dll")]
	internal static extern void PostQuitMessage(int exitCode);

	[DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
	internal static extern bool PostMessageW(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);

	[DllImport("user32.dll", SetLastError = true)]
	internal static extern UIntPtr SetTimer(IntPtr hwnd, UIntPtr eventId, uint elapseMs, IntPtr timerProc);

	[DllImport("user32.dll")]
	internal static extern bool KillTimer(IntPtr hwnd, UIntPtr eventId);

	[DllImport("user32.dll")]
	internal static extern bool SetForegroundWindow(IntPtr hwnd);

	[DllImport("user32.dll")]
	internal static extern bool GetCursorPos(out POINT point);

	[DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
	internal static extern uint RegisterWindowMessageW([MarshalAs(UnmanagedType.LPWStr)] string name);

	[DllImport("user32.dll", CharSet = CharSet.Unicode)]
	internal static extern int MessageBoxW(IntPtr hwnd, [MarshalAs(UnmanagedType.LPWStr)] string text, [MarshalAs(UnmanagedType.LPWStr)] string caption, uint type);

	[DllImport("user32.dll", SetLastError = true)]
	internal static extern IntPtr CreatePopupMenu();

	[DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
	internal static extern bool AppendMenuW(IntPtr menu, uint flags, UIntPtr idNewItem, [MarshalAs(UnmanagedType.LPWStr)] string? newItem);

	[DllImport("user32.dll", SetLastError = true)]
	internal static extern bool DestroyMenu(IntPtr menu);

	[DllImport("user32.dll", SetLastError = true)]
	internal static extern int TrackPopupMenuEx(IntPtr menu, uint flags, int x, int y, IntPtr hwnd, IntPtr parameters);

	[DllImport("user32.dll", SetLastError = true)]
	internal static extern IntPtr CreateIconIndirect(ref ICONINFO iconInfo);

	[DllImport("user32.dll", SetLastError = true)]
	internal static extern bool DestroyIcon(IntPtr icon);

	[DllImport("user32.dll", SetLastError = true)]
	internal static extern bool UpdateLayeredWindow(IntPtr hwnd, IntPtr hdcDst, ref POINT pptDst, ref SIZE psize, IntPtr hdcSrc, ref POINT pptSrc, uint crKey, ref BLENDFUNCTION pblend, int dwFlags);

	// ------------------------------------------------------------------
	// gdi32
	// ------------------------------------------------------------------
	[DllImport("gdi32.dll", SetLastError = true)]
	internal static extern IntPtr CreateCompatibleDC(IntPtr hdc);

	[DllImport("gdi32.dll", SetLastError = true)]
	internal static extern bool DeleteDC(IntPtr hdc);

	[DllImport("gdi32.dll", SetLastError = true)]
	internal static extern IntPtr CreateDIBSection(IntPtr hdc, ref BITMAPINFOHEADER bmi, uint usage, out IntPtr bits, IntPtr section, uint offset);

	[DllImport("gdi32.dll", SetLastError = true)]
	internal static extern bool DeleteObject(IntPtr obj);

	[DllImport("gdi32.dll", SetLastError = true)]
	internal static extern IntPtr SelectObject(IntPtr hdc, IntPtr obj);

	[DllImport("gdi32.dll", SetLastError = true)]
	internal static extern IntPtr CreateBitmap(int width, int height, uint planes, uint bitsPerPixel, byte[]? bits);

	// ------------------------------------------------------------------
	// dwmapi
	// ------------------------------------------------------------------
	[DllImport("dwmapi.dll")]
	internal static extern int DwmGetWindowAttribute(IntPtr hwnd, int attribute, out RECT value, int size);

	[DllImport("dwmapi.dll")]
	internal static extern int DwmGetWindowAttribute(IntPtr hwnd, int attribute, out int value, int size);

	// ------------------------------------------------------------------
	// shell32
	// ------------------------------------------------------------------
	[DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
	internal static extern bool Shell_NotifyIconW(uint message, ref NOTIFYICONDATAW data);

	// ------------------------------------------------------------------
	// kernel32
	// ------------------------------------------------------------------
	[DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
	internal static extern IntPtr GetModuleHandleW([MarshalAs(UnmanagedType.LPWStr)] string? name);

	[DllImport("kernel32.dll")]
	internal static extern uint GetCurrentProcessId();
}
