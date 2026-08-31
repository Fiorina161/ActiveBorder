using static ActiveBorder.NativeMethods;
// ReSharper disable CommentTypo

namespace ActiveBorder;

internal static class Program
{
	[STAThread]
	private static int Main()
	{
		MakeDpiAware();

		try
		{
			// Disposed in reverse order of declaration, so the tray icon is
			// removed before the hooks and overlay windows go away.
			using var tracker = new FocusTracker();
			using var tray = new TrayIcon();

			return RunMessageLoop();
		}
		catch (Exception ex)
		{
			// There is no console in a WinExe, so a failure during start-up
			// would otherwise be a silent exit with no icon and no window.
			MessageBoxW(IntPtr.Zero, ex.Message, "ActiveBorder", MB_ICONERROR);
			return 1;
		}
	}

	/**
     * Per-monitor-v2 awareness, set before any window exists.
     *
     * Without this the process would be virtualized on high-DPI monitors:
     * GetWindowRect and DWMWA_EXTENDED_FRAME_BOUNDS would come back in scaled
     * coordinates, our 5px border would be stretched by the compositor, and
     * every window on a non-primary monitor with a different scale factor would
     * be measured in the wrong coordinate space. V2 in particular is what makes
     * the values consistent across a mixed-DPI desktop.
     */
	private static void MakeDpiAware()
	{
		if (SetProcessDpiAwarenessContext(DpiAwarenessContextPerMonitorAwareV2))
			return;

		// Only reachable on builds older than Windows 10 1703.
		SetProcessDPIAware();
	}

	/**
     * The message loop is not optional decoration: out-of-context WinEvent
     * hooks are delivered by dispatching to the thread that installed them, so
     * the callbacks only fire while this loop runs.
     */
	private static int RunMessageLoop()
	{
		while (true)
		{
			var result = GetMessageW(out var msg, IntPtr.Zero, 0, 0);

			if (result == 0)
				return (int)msg.WParam;

			if (result == -1)
				return 1;

			TranslateMessage(ref msg);
			DispatchMessageW(ref msg);
		}
	}
}
