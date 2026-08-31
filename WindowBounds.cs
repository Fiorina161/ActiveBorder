using static ActiveBorder.NativeMethods;
// ReSharper disable StringLiteralTypo
// ReSharper disable CommentTypo

namespace ActiveBorder;

/**
 * Decides which windows deserve a focus border and where their visible edge
 * actually is.
 */
internal static class WindowBounds
{
	private static readonly uint _ownProcessId = GetCurrentProcessId();

	/**
     * Shell surfaces that are never a meaningful "focused application". The
     * desktop keeps foreground whenever you click empty wallpaper, and the
     * taskbar takes foreground on Win+T, on tray interaction, etc.
     */
	private static readonly string[] _ignoredClasses = [
		// desktop (Program Manager)
		// desktop wallpaper host
		// primary taskbar
		// taskbar on secondary monitors
		// tray overflow flyout
		// start menu / search / shell flyouts
		// task view, Alt-Tab, snap assist
		"Progman", "WorkerW", "Shell_TrayWnd", "Shell_SecondaryTrayWnd", "NotifyIconOverflowWindow", "Windows.UI.Core.CoreWindow", "XamlExplorerHostIslandWindow"
	];

	[ThreadStatic] private static char[]? _classNameBuffer;

	/** True when the window sits in the topmost z-order band. */
	internal static bool IsTopmost(IntPtr hwnd) => (GetWindowLongPtr(hwnd, GWL_EXSTYLE).ToInt64() & WS_EX_TOPMOST) != 0;

	/**
     * True when hwnd is a real, visible, interactive top-level window that
     * should receive a border.
     */
	internal static bool IsEligible(IntPtr hwnd)
	{
		if (hwnd == IntPtr.Zero)
			return false;

		if (!IsWindow(hwnd))
			return false;

		if (!IsWindowVisible(hwnd))
			return false;

		if (IsIconic(hwnd))
			return false;

		// Never decorate our own overlay or helper windows.
		GetWindowThreadProcessId(hwnd, out var pid);

		if (pid == _ownProcessId)
			return false;

		// DWM-cloaked windows are "visible" by the classic API but are not
		// actually on screen: suspended UWP apps, windows on another
		// virtual desktop, Explorer's hidden CabinetWClass instances.
		if (DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, out int cloaked, sizeof(int)) == 0 && cloaked != 0)
			return false;

		return !IsIgnoredClass(hwnd);
	}

	private static bool IsIgnoredClass(IntPtr hwnd)
	{
		var buffer = _classNameBuffer ??= new char[256];
		var length = GetClassNameW(hwnd, buffer, buffer.Length);

		if (length <= 0)
			return false;

		var name = new ReadOnlySpan<char>(buffer, 0, length);

		foreach (var ignored in _ignoredClasses)
			if (name.Equals(ignored, StringComparison.Ordinal))
				return true;

		return false;
	}

	/**
     * The visible outer edge of a window, in physical pixels on the virtual
     * screen. Coordinates may be negative on multi-monitor setups.
     *
     * GetWindowRect includes the invisible resize border that DWM adds to
     * sizable windows (typically 7-8px per side at 100% scaling), so it would
     * place the border well outside the pixels the user sees.
     * DWMWA_EXTENDED_FRAME_BOUNDS reports the frame DWM actually draws.
     */
	internal static bool TryGetVisibleBounds(IntPtr hwnd, out RECT bounds)
	{
		var hr = DwmGetWindowAttribute(hwnd, DWMWA_EXTENDED_FRAME_BOUNDS, out bounds, 16 /* sizeof(RECT) */);

		if (hr == 0 && !bounds.IsEmpty)
			return true;

		// Fall back for windows DWM does not track (and for the rare case
		// where composition is unavailable).
		return GetWindowRect(hwnd, out bounds) && !bounds.IsEmpty;
	}
}
