using System.Runtime.InteropServices;
using static ActiveBorder.NativeMethods;
// ReSharper disable PrivateFieldCanBeConvertedToLocalVariable
// ReSharper disable CommentTypo

namespace ActiveBorder;

/**
 * Watches the foreground window and keeps the overlay glued to it.
 *
 * Focus changes are event driven (EVENT_SYSTEM_FOREGROUND). Geometry changes
 * are event driven too (EVENT_OBJECT_LOCATIONCHANGE, hooked only on the
 * target's process, never system-wide). A timer runs as a safety net for the
 * cases events do not cover: elevated targets, where UIPI silently drops every
 * WinEvent we would otherwise receive, and any app that resizes without
 * notifying the accessibility layer. That timer idles at 5 Hz and only steps up
 * to 30 Hz once polling actually catches a change events missed, decaying back
 * afterward.
 */
internal sealed class FocusTracker : IDisposable
{
	private const string CLASS_NAME = "ActiveBorderController";

	private const uint IDLE_INTERVAL_MS = 200;
	private const uint FAST_INTERVAL_MS = 33;
	private const int FAST_DECAY_TICKS = 45;
	private const int Z_ORDER_COOLDOWN_TICKS = 5;
	private const int TIMER_ID = 1;

	private readonly OverlayWindow _overlay = new();

	// Delegates handed to Win32 must stay reachable for the lifetime of the
	// hook / window class, otherwise the GC collects the thunk and the next
	// callback tears down the process.
	private readonly WndProc _wndProc;
	private readonly WinEventProc _systemEventProc;
	private readonly WinEventProc _objectEventProc;

	private readonly IntPtr _messageWindow;
	private ushort _classAtom;

	private IntPtr _foregroundHook;
	private IntPtr _moveSizeHook;
	private IntPtr _minimizeHook;
	private IntPtr _objectHook;

	private IntPtr _target;
	private RECT _lastBounds;
	private bool _hasBounds;
	private bool _inMoveSize;

	private uint _timerInterval;
	private int _fastTicksRemaining;
	private int _zOrderCooldown;
	private bool _disposed;

	internal FocusTracker()
	{
		_wndProc = ControllerWndProc;
		_systemEventProc = OnSystemEvent;
		_objectEventProc = OnObjectEvent;

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
			throw new InvalidOperationException("RegisterClassEx failed for the controller: " + Marshal.GetLastWin32Error());

		// A hidden top-level window rather than a message-only one: broadcast
		// messages such as WM_DISPLAYCHANGE are not delivered to HWND_MESSAGE
		// windows, and we want to know when the desktop geometry changes.
		_messageWindow = CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, CLASS_NAME, "ActiveBorder", WS_POPUP, 0, 0, 0, 0, IntPtr.Zero, IntPtr.Zero, instance, IntPtr.Zero);

		if (_messageWindow == IntPtr.Zero)
			throw new InvalidOperationException("CreateWindowEx failed for the controller: " + Marshal.GetLastWin32Error());

		_foregroundHook = Hook(EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND, _systemEventProc);
		_moveSizeHook = Hook(EVENT_SYSTEM_MOVESIZESTART, EVENT_SYSTEM_MOVESIZEEND, _systemEventProc);
		_minimizeHook = Hook(EVENT_SYSTEM_MINIMIZESTART, EVENT_SYSTEM_MINIMIZEEND, _systemEventProc);

		SetTimerInterval(IDLE_INTERVAL_MS);

		// Pick up whatever is already focused at startup.
		AttachTo(GetForegroundWindow());
	}

	/** Handle callers can post WM_CLOSE to in order to quit. */
	internal IntPtr MessageWindow => _messageWindow;

	private static IntPtr Hook(uint min, uint max, WinEventProc callback) => SetWinEventHook(min, max, IntPtr.Zero, callback, 0, 0, WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS);

	// ------------------------------------------------------------------
	// Target management
	// ------------------------------------------------------------------

	private void AttachTo(IntPtr hwnd)
	{
		if (!WindowBounds.IsEligible(hwnd))
		{
			Detach();
			return;
		}

		if (hwnd == _target)
		{
			// Same window, but re-activating it raised it above our strips,
			// so the z-order has to be re-applied.
			Refresh(reassertZOrder: true);
			return;
		}

		ReleaseObjectHook();

		_target = hwnd;
		_hasBounds = false;
		_inMoveSize = false;
		_zOrderCooldown = 0;

		// Scope the geometry hook to the target's process. A system-wide
		// EVENT_OBJECT_LOCATIONCHANGE hook would deliver an event for every
		// caret blink and mouse-over highlight on the machine.
		GetWindowThreadProcessId(hwnd, out var pid);
		_objectHook = SetWinEventHook(EVENT_OBJECT_DESTROY, EVENT_OBJECT_LOCATIONCHANGE, IntPtr.Zero, _objectEventProc, pid, 0, WINEVENT_OUTOFCONTEXT);

		Refresh(reassertZOrder: true);
	}

	private void Detach()
	{
		ReleaseObjectHook();
		_target = IntPtr.Zero;
		_hasBounds = false;
		_inMoveSize = false;
		_overlay.Hide();

		// Deliberately not forcing the timer back to idle here. Detach runs
		// on every retry against a foreground window that is not (yet)
		// eligible, and resetting the interval would cancel the fast retry
		// that is trying to catch that window as soon as it settles.
		// DecayFast winds the timer down instead.
	}

	private void ReleaseObjectHook()
	{
		if (_objectHook == IntPtr.Zero)
			return;
		UnhookWinEvent(_objectHook);
		_objectHook = IntPtr.Zero;
	}

	/**
     * Re-measure the target and move the border. Returns true if the geometry
     * had actually changed.
     */
	private bool Refresh(bool reassertZOrder)
	{
		if (_target == IntPtr.Zero)
			return false;

		if (!IsWindow(_target))
		{
			Detach();
			return false;
		}

		// Still the same HWND, but temporarily not on screen (minimized,
		// hidden, or cloaked onto another virtual desktop).
		if (!IsWindowVisible(_target) || IsIconic(_target) || IsCloaked(_target) || !WindowBounds.TryGetVisibleBounds(_target, out var bounds))
		{
			_overlay.Hide();
			_hasBounds = false;
			return false;
		}

		var changed = !_hasBounds || !bounds.SameAs(_lastBounds);
		if (!changed && !reassertZOrder)
			return false;

		_overlay.Show(_target, bounds, reassertZOrder);
		_lastBounds = bounds;
		_hasBounds = true;
		return changed;
	}

	private static bool IsCloaked(IntPtr hwnd) => DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, out int cloaked, sizeof(int)) == 0 && cloaked != 0;

	// ------------------------------------------------------------------
	// WinEvent callbacks (delivered on this thread while it pumps messages)
	// ------------------------------------------------------------------

	private void OnSystemEvent(IntPtr hook, uint eventType, IntPtr hwnd, int idObject, int idChild, uint thread, uint time)
	{
		if (idObject != OBJID_WINDOW || idChild != CHILDID_SELF)
			return;

		switch (eventType)
		{
			case EVENT_SYSTEM_FOREGROUND:
				AttachTo(hwnd);

				// Rejected, but something does hold the foreground: it is
				// most likely a window still being created. Retry at 30 Hz
				// for a moment so the border appears as soon as it settles
				// rather than up to a whole idle interval later.
				if (_target == IntPtr.Zero && hwnd != IntPtr.Zero)
					GoFast();
				break;

			case EVENT_SYSTEM_MOVESIZESTART:
				if (hwnd != _target)
					break;
				_inMoveSize = true;
				GoFast();
				break;

			case EVENT_SYSTEM_MOVESIZEEND:
				if (hwnd != _target)
					break;
				_inMoveSize = false;
				Refresh(reassertZOrder: true);
				break;

			case EVENT_SYSTEM_MINIMIZESTART:
				if (hwnd != _target)
					break;
				_overlay.Hide();
				_hasBounds = false;
				break;

			case EVENT_SYSTEM_MINIMIZEEND:
				if (hwnd != _target)
					break;
				Refresh(reassertZOrder: true);
				break;
		}
	}

	private void OnObjectEvent(IntPtr hook, uint eventType, IntPtr hwnd, int idObject, int idChild, uint thread, uint time)
	{
		// The hook is filtered by process, not by window: ignore controls,
		// carets, menus and every other child object inside the target app.
		if (hwnd != _target || idObject != OBJID_WINDOW || idChild != CHILDID_SELF)
			return;

		switch (eventType)
		{
			case EVENT_OBJECT_LOCATIONCHANGE:
			case EVENT_OBJECT_SHOW:
				Refresh(reassertZOrder: false);
				break;

			case EVENT_OBJECT_HIDE:
				_overlay.Hide();
				_hasBounds = false;
				break;

			case EVENT_OBJECT_DESTROY:
				Detach();
				break;
		}
	}

	// ------------------------------------------------------------------
	// Safety-net timer
	// ------------------------------------------------------------------

	private void OnTick()
	{
		// Reconcile against the window we are actually attached to, not
		// against the last one we happened to look at.
		//
		// A window that has just been created is routinely not yet eligible
		// at the instant its EVENT_SYSTEM_FOREGROUND arrives: DWM still has
		// it cloaked for the open animation, or it has no size yet. Comparing
		// against the last HWND *seen* meant such a window was rejected once
		// and then never looked at again, because the foreground HWND never
		// changed afterward - so a freshly launched app got no border until
		// the user clicked away and back. Comparing against _target instead
		// means we keep retrying until we are attached to whatever holds the
		// foreground.
		var foreground = GetForegroundWindow();
		if (foreground != _target)
			AttachTo(foreground);

		if (_target == IntPtr.Zero)
		{
			DecayFast();
			return;
		}

		// Cheap check that nothing has slipped between the target and its
		// border; skipped mid-drag, where re-ordering would only add flicker.
		// The cooldown bounds the damage if some window genuinely cannot be
		// got under (an owned dialog, say) so we never re-order in a loop.
		var zOrderBroken = false;

		if (_zOrderCooldown > 0)
			_zOrderCooldown--;
		else if (!_inMoveSize && _hasBounds && !_overlay.IsAbove(_target))
		{
			zOrderBroken = true;
			_zOrderCooldown = Z_ORDER_COOLDOWN_TICKS;
		}

		if (Refresh(reassertZOrder: zOrderBroken))
		{
			// Polling found a move that no event told us about. Something in
			// this target is invisible to WinEvents, so track it eagerly for
			// a while.
			GoFast();
		}
		else
		{
			DecayFast();
		}
	}

	private void GoFast()
	{
		_fastTicksRemaining = FAST_DECAY_TICKS;
		SetTimerInterval(FAST_INTERVAL_MS);
	}

	private void DecayFast()
	{
		if (_fastTicksRemaining > 0 && --_fastTicksRemaining == 0)
		{
			// Nothing has moved for a while. If the end of a move/size loop
			// was never delivered - the target died mid-drag, or the event
			// was dropped - stop believing we are still in one, rather than
			// polling at 30 Hz for the rest of the process lifetime.
			_inMoveSize = false;
			SetTimerInterval(IDLE_INTERVAL_MS);
		}
	}

	private void SetTimerInterval(uint intervalMs)
	{
		if (_timerInterval == intervalMs)
			return;
		_timerInterval = intervalMs;
		SetTimer(_messageWindow, new UIntPtr(TIMER_ID), intervalMs, IntPtr.Zero);
	}

	// ------------------------------------------------------------------
	// Controller window
	// ------------------------------------------------------------------

	private IntPtr ControllerWndProc(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam)
	{
		switch (msg)
		{
			case WM_TIMER:
				if (wParam.ToInt64() == TIMER_ID)
					OnTick();
				return IntPtr.Zero;

			case WM_DISPLAYCHANGE:
				_overlay.OnDisplayChanged();
				_hasBounds = false;
				Refresh(reassertZOrder: true);
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

	public void Dispose()
	{
		if (_disposed)
			return;
		_disposed = true;

		// Unhook before tearing anything else down: a WinEvent callback that
		// arrives after the overlay is gone would run against dead handles.
		foreach (var hook in new[] { _foregroundHook, _moveSizeHook, _minimizeHook, _objectHook })
			if (hook != IntPtr.Zero)
				UnhookWinEvent(hook);

		_foregroundHook = _moveSizeHook = _minimizeHook = _objectHook = IntPtr.Zero;

		if (_messageWindow != IntPtr.Zero)
		{
			KillTimer(_messageWindow, new UIntPtr(TIMER_ID));
			DestroyWindow(_messageWindow);
		}

		_overlay.Dispose();

		if (_classAtom != 0)
		{
			UnregisterClassW(CLASS_NAME, GetModuleHandleW(null));
			_classAtom = 0;
		}
	}
}
