using System.Runtime.InteropServices;
using static ActiveBorder.NativeMethods;
// ReSharper disable CommentTypo
// ReSharper disable PrivateFieldCanBeConvertedToLocalVariable

namespace ActiveBorder;

/**
 * The notification-area icon and its right-click menu. This is the only user
 * interface the utility has, and the only way to shut it down.
 */
internal sealed class TrayIcon : IDisposable
{
	private const string CLASS_NAME = "ActiveBorderTray";
	private const string TOOLTIP = "ActiveBorder - focus border";

	private const uint ICON_ID = 1;
	private const uint COMMAND_EXIT = 100;

	/** Private message the shell sends us for icon mouse events. */
	private const uint TRAY_CALLBACK_MESSAGE = WM_APP + 1;

	// Handed to Win32 inside a WNDCLASSEX and never called by managed code,
	// so it has to stay reachable for as long as the window exists.
	private readonly WndProc _wndProc;

	private readonly IntPtr _window;
	private readonly IntPtr _icon;
	private readonly IntPtr _menu;

	/**
     * Broadcast by the shell when Explorer restarts. Every notification-area
     * icon is destroyed at that point and has to be added again, or the utility
     * keeps running with no way to reach it.
     */
	private readonly uint _taskbarCreated;

	private ushort _classAtom;
	private bool _iconAdded;
	private bool _disposed;

	internal TrayIcon()
	{
		_wndProc = TrayWndProc;

		var instance = GetModuleHandleW(null);

		var wc = new WNDCLASSEXW
		{
			CbSize = (uint)Marshal.SizeOf<WNDCLASSEXW>(),
			LpfnWndProc = Marshal.GetFunctionPointerForDelegate(_wndProc),
			HInstance = instance,
			LpszClassName = CLASS_NAME,
		};

		_classAtom = RegisterClassExW(ref wc);
		if (_classAtom == 0)
			throw new InvalidOperationException("RegisterClassEx failed for the tray window: " + Marshal.GetLastWin32Error());

		// Never shown. WS_EX_TOOLWINDOW keeps it out of the taskbar and
		// Alt-Tab; note the deliberate absence of WS_EX_NOACTIVATE, because
		// the tray menu needs this window to be able to take the foreground.
		_window = CreateWindowExW(WS_EX_TOOLWINDOW, CLASS_NAME, "ActiveBorder", WS_POPUP, 0, 0, 0, 0, IntPtr.Zero, IntPtr.Zero, instance, IntPtr.Zero);

		if (_window == IntPtr.Zero)
			throw new InvalidOperationException("CreateWindowEx failed for the tray window: " + Marshal.GetLastWin32Error());

		_taskbarCreated = RegisterWindowMessageW("TaskbarCreated");

		_icon = CreateBorderIcon(GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON));

		_menu = CreatePopupMenu();

		if (_menu == IntPtr.Zero)
			throw new InvalidOperationException("CreatePopupMenu failed: " + Marshal.GetLastWin32Error());

		AppendMenuW(_menu, MF_STRING, new UIntPtr(COMMAND_EXIT), "E&xit ActiveBorder");

		if (!AddIcon())
			throw new InvalidOperationException("Shell_NotifyIcon(NIM_ADD) failed: " + Marshal.GetLastWin32Error());
	}

	private bool AddIcon()
	{
		var data = NewIconData();
		data.UFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
		data.UCallbackMessage = TRAY_CALLBACK_MESSAGE;
		data.HIcon = _icon;
		data.SzTip = TOOLTIP;

		_iconAdded = Shell_NotifyIconW(NIM_ADD, ref data);
		return _iconAdded;
	}

	private NOTIFYICONDATAW NewIconData() => new()
	{
		CbSize = (uint)Marshal.SizeOf<NOTIFYICONDATAW>(),
		HWnd = _window,
		UID = ICON_ID,
		SzTip = string.Empty,
		SzInfo = string.Empty,
		SzInfoTitle = string.Empty,
	};

	private IntPtr TrayWndProc(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam)
	{
		if (msg == TRAY_CALLBACK_MESSAGE)
		{
			// Classic (pre-version-4) callback packing: wParam is the icon id
			// and lParam is the mouse message.
			if ((uint)lParam.ToInt64() == WM_RBUTTONUP)
				ShowContextMenu();

			return IntPtr.Zero;
		}

		if (msg == _taskbarCreated && _taskbarCreated != 0)
		{
			AddIcon();
			return IntPtr.Zero;
		}

		switch (msg)
		{
			case WM_COMMAND:
				if ((wParam.ToInt64() & 0xFFFF) == COMMAND_EXIT)
					PostQuitMessage(0);
				return IntPtr.Zero;

			case WM_CLOSE:
				DestroyWindow(hwnd);
				return IntPtr.Zero;

			case WM_DESTROY:
				PostQuitMessage(0);
				return IntPtr.Zero;
		}

		return DefWindowProcW(hwnd, msg, wParam, lParam);
	}

	/**
     * Pop the menu at the cursor.
     *
     * The SetForegroundWindow call before and the WM_NULL post after are the
     * long-standing shell requirement (KB135788). Without them the menu does
     * not dismiss when the user clicks away from it and is left stuck on
     * screen.
     */
	private void ShowContextMenu()
	{
		SetForegroundWindow(_window);
		GetCursorPos(out var cursor);
		TrackPopupMenuEx(_menu, TPM_LEFTALIGN | TPM_RIGHTBUTTON, cursor.X, cursor.Y, _window, IntPtr.Zero);
		PostMessageW(_window, WM_NULL, IntPtr.Zero, IntPtr.Zero);
	}

	/**
     * Build the tray icon in memory: a hollow square in the border colour, what
     * the utility draws on screen. Generating it avoids shipping a binary .ico
     * alongside a project whose whole point is minimalism.
     */
	private static IntPtr CreateBorderIcon(int width, int height)
	{
		var ring = Math.Max(2, Math.Min(width, height) / 6);

		var header = new BITMAPINFOHEADER
		{
			// negative: top-down rows
			BiSize = (uint)Marshal.SizeOf<BITMAPINFOHEADER>(),
			BiWidth = width,
			BiHeight = -height,
			BiPlanes = 1,
			BiBitCount = 32,
			BiCompression = BI_RGB,
		};

		var colorBitmap = CreateDIBSection(IntPtr.Zero, ref header, DIB_RGB_COLORS, out var bits, IntPtr.Zero, 0);

		if (colorBitmap == IntPtr.Zero || bits == IntPtr.Zero)
			throw new InvalidOperationException("CreateDIBSection failed for the tray icon.");

		// Opaque on the ring, fully transparent inside. Both cases are
		// alpha 0xFF or 0x00, where premultiplied and straight alpha agree,
		// so no premultiplication maths is needed.
		var pixels = new int[width * height];

		for (var y = 0; y < height; y++)
			for (var x = 0; x < width; x++)
			{
				var onRing = x < ring || y < ring || x >= width - ring || y >= height - ring;
				pixels[y * width + x] = onRing ? unchecked((int)OverlayWindow.BORDER_COLOR_ARGB) : 0;
			}
		Marshal.Copy(pixels, 0, bits, pixels.Length);

		// CreateIconIndirect still wants an AND mask. All-zero means "take the
		// colour bitmap everywhere" and lets the alpha channel do the work.
		var maskStride = (width + 31) / 32 * 4;
		var maskBitmap = CreateBitmap(width, height, 1, 1, new byte[maskStride * height]);

		var info = new ICONINFO
		{
			FIcon = true,
			HbmMask = maskBitmap,
			HbmColor = colorBitmap,
		};

		var icon = CreateIconIndirect(ref info);

		// CreateIconIndirect copies the bitmaps; the originals are ours
		// to free.
		DeleteObject(colorBitmap);
		DeleteObject(maskBitmap);

		if (icon == IntPtr.Zero)
			throw new InvalidOperationException($"CreateIconIndirect failed for the tray icon: {Marshal.GetLastWin32Error()}");

		return icon;
	}

	public void Dispose()
	{
		if (_disposed)
			return;
		_disposed = true;

		// Remove the icon first: leaving it behind gives the user a ghost
		// icon that only disappears when they hover over it.
		if (_iconAdded)
		{
			var data = NewIconData();
			Shell_NotifyIconW(NIM_DELETE, ref data);
			_iconAdded = false;
		}

		if (_menu != IntPtr.Zero)
			DestroyMenu(_menu);

		if (_icon != IntPtr.Zero)
			DestroyIcon(_icon);

		if (_window != IntPtr.Zero)
			DestroyWindow(_window);

		if (_classAtom != 0)
		{
			UnregisterClassW(CLASS_NAME, GetModuleHandleW(null));
			_classAtom = 0;
		}
	}
}
