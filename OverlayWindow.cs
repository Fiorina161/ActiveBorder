using System.Runtime.InteropServices;
using static ActiveBorder.NativeMethods;
// ReSharper disable CommentTypo

namespace ActiveBorder;

/**
 * The focus border itself: four thin, layered, click-through popup windows
 * forming a rectangle around the target.
 *
 * Four strips rather than one big frame-shaped window, because a single overlay
 * covering the whole target would need an UpdateLayeredWindow bitmap the size
 * of that window (~33 MB for a maximized 4K window) and a same-sized DWM
 * redirection surface. Four strips only ever need two small solid bitmaps,
 * reused for the lifetime of the process, and they leave the interior of the
 * target completely untouched rather than merely transparent.
 */
internal sealed class OverlayWindow : IDisposable
{
	// 0xAARRGGBB, alpha-premultiplied. Alpha is 0xFF so the premultiplied
	// channels equal the straight ones.
	//
	// Internal rather than private because the tray icon paints itself in the
	// same colour: one constant, so the icon and the border cannot drift
	// apart from each other.
	internal const uint BORDER_COLOR_ARGB = 0xFFFF0000;

	// The other half of the hazard pattern. Both colours are fully opaque,
	// the case where premultiplied and straight alpha agree, so the blend
	// needs no premultiply maths.
	private const uint STRIPE_COLOR_ARGB = 0xFFFFFFFF;

	/**
	 * Length of one red plus one white band measured along an edge, in
	 * physical pixels. The bands run at 45 degrees, so the width you actually
	 * see across a band is about 0.35 of this.
	 */
	private const int STRIPE_PERIOD = 12;

	/**
     * Border width in physical pixels. The process is per-monitor DPI aware,
     * so this is not scaled by the system.
     */
	internal const int THICKNESS = 5;

	private const string CLASS_NAME = "ActiveBorderOverlay";

	private const int TOP = 0, BOTTOM = 1, LEFT = 2, RIGHT = 3;

	// The walk has to clear four strips plus the invisible helper
	// windows (IME hosts and friends) interleaved among them.
	private const int Z_ORDER_PROBE_LIMIT = 32;

	private readonly IntPtr[] _edges = new IntPtr[4];
	private readonly RECT[] _edgeRects = new RECT[4];

	// Outer rectangle of the border as last drawn; used to decide
	// whether another window actually overlaps it.
	private RECT _bounds;

	// Two solid-colour DIB sections, each permanently selected into its own
	// memory DC: one long-and-short for the horizontal edges, one
	// short-and-tall for the vertical edges. UpdateLayeredWindow is happy to
	// take a source bitmap larger than the destination window.
	private IntPtr _horizontalDc, _horizontalBitmap, _horizontalOldBitmap;
	private IntPtr _verticalDc, _verticalBitmap, _verticalOldBitmap;
	private int _stripLength;

	private bool _visible;
	private bool _topmost;
	private bool _disposed;

	// The window procedure is handed to Win32 inside a WNDCLASSEX, so the
	// delegate must outlive every window of the class. A static field keeps
	// it rooted; a local would be collected and the next message would fault.
	private static readonly WndProc _sWndProc = OverlayWndProc;
	private static ushort _sClassAtom;

	internal OverlayWindow()
	{
		var instance = GetModuleHandleW(null);
		EnsureClassRegistered(instance);
		CreateStripBitmaps();

		for (var i = 0; i < _edges.Length; i++)
		{
			// Layered for per-pixel alpha via UpdateLayeredWindow, transparent so
			// hit-testing falls through to whatever is below, no-activate so a
			// click never activates it, and tool-window to stay out of the taskbar
			// and Alt-Tab. WS_POPUP: no caption, no border, no owner.
			_edges[i] = CreateWindowExW(WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW, CLASS_NAME, null, WS_POPUP, 0, 0, 0, 0, IntPtr.Zero, IntPtr.Zero, instance, IntPtr.Zero);

			if (_edges[i] == IntPtr.Zero)
				throw new InvalidOperationException($"CreateWindowEx failed for the overlay: {Marshal.GetLastWin32Error()}");
		}
	}

	/** True if this handle belongs to the overlay. */
	internal bool Owns(IntPtr hwnd) => hwnd == _edges[0] || hwnd == _edges[1] || hwnd == _edges[2] || hwnd == _edges[3];

	/**
     * Draw the border on the outermost Thickness pixels inside bounds,
     * directly above target in the z-order. bounds is the visible frame of
     * the target, in physical pixels on the virtual screen.
     *
     * Z-order is only re-applied when reassertZOrder is set, because a
     * SetWindowPos that moves windows in the z-order on every mouse-move of a
     * drag is both wasteful and a source of flicker.
     */
	internal void Show(IntPtr target, in RECT bounds, bool reassertZOrder)
	{
		// A window narrower or shorter than two borders has nowhere sensible
		// to put a rectangle.
		if (bounds.Width < THICKNESS * 2 || bounds.Height < THICKNESS * 2)
		{
			Hide();
			return;
		}

		// The border is drawn just inside the visible frame rather than just
		// outside it. Outside would fall off the screen (or under the
		// taskbar) for maximized and snapped windows, which is exactly where
		// a focus indicator is most needed.
		var top = Rect(bounds.Left, bounds.Top, bounds.Right, bounds.Top + THICKNESS);
		var bottom = Rect(bounds.Left, bounds.Bottom - THICKNESS, bounds.Right, bounds.Bottom);
		var left = Rect(bounds.Left, bounds.Top + THICKNESS, bounds.Left + THICKNESS, bounds.Bottom - THICKNESS);
		var right = Rect(bounds.Right - THICKNESS, bounds.Top + THICKNESS, bounds.Right, bounds.Bottom - THICKNESS);

		_bounds = bounds;

		UpdateEdge(TOP, top, horizontal: true);
		UpdateEdge(BOTTOM, bottom, horizontal: true);
		UpdateEdge(LEFT, left, horizontal: false);
		UpdateEdge(RIGHT, right, horizontal: false);

		if (!_visible)
		{
			foreach (var edge in _edges)
				ShowWindow(edge, SW_SHOWNOACTIVATE);

			_visible = true;
			reassertZOrder = true;
		}

		if (reassertZOrder)
			ApplyZOrder(target);
	}

	internal void Hide()
	{
		if (!_visible)
			return;

		foreach (var edge in _edges)
			ShowWindow(edge, SW_HIDE);

		_visible = false;
	}

	/**
     * True when nothing has slipped between the target and the border.
     *
     * Deliberately not a plain GW_HWNDPREV comparison. The z-order is full of
     * windows that are never drawn - IME hosts such as "MSCTFIME UI", 0x0
     * helper windows, hidden shell surfaces - and any of them can sit between
     * the target and our strips. Treating those as an obstruction would
     * re-order four windows on every timer tick forever.
     */
	internal bool IsAbove(IntPtr target)
	{
		if (!_visible)
			return false;

		// Every strip has to be above the target, not just one of them. An
		// earlier version returned on the first hit, which meant a target
		// that raised itself part-way through ApplyZOrder could leave three
		// strips stranded below it and still be reported healthy - so the
		// border showed only one of its four edges, permanently.
		var found = 0;
		var walker = target;
		for (var i = 0; i < Z_ORDER_PROBE_LIMIT; i++)
		{
			walker = GetWindow(walker, GW_HWNDPREV);
			if (walker == IntPtr.Zero)
				break;

			if (Owns(walker))
			{
				if (++found == _edges.Length)
					return true;
				continue;
			}

			if (Obscures(walker))
				return false;
		}
		return found == _edges.Length;
	}

	/** True if this window is actually painted over the border. */
	private bool Obscures(IntPtr hwnd) => IsWindowVisible(hwnd) && GetWindowRect(hwnd, out var r) && !r.IsEmpty && r.Left < _bounds.Right && r.Right > _bounds.Left && r.Top < _bounds.Bottom && r.Bottom > _bounds.Top;

	private void UpdateEdge(int index, in RECT rect, bool horizontal)
	{
		if (rect.IsEmpty)
			return;

		// Guard against a window somehow larger than the bitmaps we sized to
		// the virtual screen; clamping is better than a failed draw.
		var width = Math.Min(rect.Width, horizontal ? _stripLength : THICKNESS);
		var height = Math.Min(rect.Height, horizontal ? THICKNESS : _stripLength);
		if (width <= 0 || height <= 0)
			return;

		if (_edgeRects[index].SameAs(rect) && _visible)
			return;

		_edgeRects[index] = rect;

		var destination = new POINT(rect.Left, rect.Top);
		var size = new SIZE(width, height);
		// Anchor the pattern to screen coordinates so the diagonals run
		// continuously around all four edges instead of each restarting at
		// its own corner. The source pixel under screen (x, y) must satisfy
		// (offset + i) + j == (x + i) + (y + j), so the offset is x + y
		// reduced modulo the period. The double modulo keeps it positive on
		// a monitor left of the primary, where the coordinates go negative.
		var phase = (((rect.Left + rect.Top) % STRIPE_PERIOD) + STRIPE_PERIOD) % STRIPE_PERIOD;
		var source = horizontal ? new POINT(phase, 0) : new POINT(0, phase);
		var blend = new BLENDFUNCTION
		{
			BlendOp = AC_SRC_OVER,
			BlendFlags = 0,
			SourceConstantAlpha = 255,
			AlphaFormat = AC_SRC_ALPHA,
		};

		// One call moves, resizes and repaints the strip atomically, so there
		// is no window in which a stale or half-positioned border is visible.
		UpdateLayeredWindow(_edges[index], IntPtr.Zero, ref destination, ref size, horizontal ? _horizontalDc : _verticalDc, ref source, 0, ref blend, ULW_ALPHA);
	}

	/**
     * Put the strips directly above the target instead of making them globally
     * topmost, so they never cover unrelated windows.
     *
     * Note the direction of SetWindowPos: hWndInsertAfter names the window the
     * positioned window is placed *behind*. Passing the target itself therefore
     * puts the border underneath it, where - since the border is drawn inside
     * the frame - it is completely invisible. The anchor has to be the window
     * immediately above the target instead.
     */
	private void ApplyZOrder(IntPtr target)
	{
		if (!IsWindow(target))
			return;

		var targetTopmost = WindowBounds.IsTopmost(target);

		// Topmost is a separate z-order band, and membership is sticky. Match
		// the target's band, so a border on an ordinary window never floats
		// over everything else.
		if (_topmost != targetTopmost)
		{
			var band = targetTopmost ? HWND_TOPMOST : HWND_NOTOPMOST;
			foreach (var edge in _edges)
			{
				SetWindowPos(edge, band, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_NOOWNERZORDER | SWP_NOSENDCHANGING);
			}
			_topmost = targetTopmost;
		}

		var insertAfter = FindAnchorAbove(target, targetTopmost);

		// Chain the strips to each other rather than inserting all four at
		// the same anchor. These are four separate calls, and an application
		// that raises itself in between them - Teams and other WebView2 and
		// Electron shells do - would otherwise leave the remaining strips
		// stranded below the target while the first stayed above it. Chained,
		// the four always stay contiguous and move as one group.
		var after = insertAfter;
		foreach (var edge in _edges)
		{
			SetWindowPos(edge, after, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_NOOWNERZORDER | SWP_NOSENDCHANGING);
			after = edge;
		}
	}

	/**
     * The window to sit behind so that we land immediately above target, or
     * HWND_TOP when there is nothing usable.
     */
	private IntPtr FindAnchorAbove(IntPtr target, bool targetTopmost)
	{
		var walker = target;
		for (var i = 0; i < Z_ORDER_PROBE_LIMIT; i++)
		{
			walker = GetWindow(walker, GW_HWNDPREV);

			// Nothing above the target at all: the top of the band will do.
			if (walker == IntPtr.Zero)
				break;

			// Skip the strips themselves, or we would anchor to where we
			// already are and never actually move.
			if (Owns(walker))
				continue;

			// An anchor in the other z-order band is unusable: the system
			// would clamp us to the edge of our own band anyway, and which
			// side of the target that lands on is not defined.
			if (WindowBounds.IsTopmost(walker) != targetTopmost)
				break;

			return walker;
		}

		// Top of our band. The focused window is normally already at the top
		// of the non-topmost band, so this puts the border just above it.
		return HWND_TOP;
	}

	// ------------------------------------------------------------------
	// Bitmaps
	// ------------------------------------------------------------------

	/**
     * Rebuild the strip bitmaps if the virtual screen has grown (monitor
     * hot-plug or resolution change).
     */
	internal void OnDisplayChanged()
	{
		if (RequiredStripLength() <= _stripLength)
			return;

		Array.Clear(_edgeRects);
		DestroyStripBitmaps();
		CreateStripBitmaps();
	}

	private static int RequiredStripLength()
	{
		var width = GetSystemMetrics(SM_CXVIRTUALSCREEN);
		var height = GetSystemMetrics(SM_CYVIRTUALSCREEN);

		// A little slack covers windows that overhang the virtual screen.
		return Math.Max(Math.Max(width, height), 1024) + 256;
	}

	private void CreateStripBitmaps()
	{
		_stripLength = RequiredStripLength();

		_horizontalDc = CreateCompatibleDC(IntPtr.Zero);
		// The extra period is headroom for the phase offset that anchors the
		// pattern to screen coordinates; see UpdateEdge.
		_horizontalBitmap = CreateStripeDib(_stripLength + STRIPE_PERIOD, THICKNESS);
		_horizontalOldBitmap = SelectObject(_horizontalDc, _horizontalBitmap);

		_verticalDc = CreateCompatibleDC(IntPtr.Zero);
		_verticalBitmap = CreateStripeDib(THICKNESS, _stripLength + STRIPE_PERIOD);
		_verticalOldBitmap = SelectObject(_verticalDc, _verticalBitmap);
	}

	private static IntPtr CreateStripeDib(int width, int height)
	{
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

		var bitmap = CreateDIBSection(IntPtr.Zero, ref header, DIB_RGB_COLORS, out var bits, IntPtr.Zero, 0);

		if (bitmap == IntPtr.Zero || bits == IntPtr.Zero)
			throw new InvalidOperationException("CreateDIBSection failed for the border bitmap.");

		var pixelCount = width * height;
		var pixels = new int[pixelCount];
		var red = unchecked((int)BORDER_COLOR_ARGB);
		var white = unchecked((int)STRIPE_COLOR_ARGB);

		// Pixels sharing a value of x + y lie on a 45 degree line, so
		// thresholding that sum inside one period gives diagonal bands
		// leaning the way a forward slash does.
		for (var y = 0; y < height; y++)
			for (var x = 0; x < width; x++)
				pixels[(y * width) + x] = (x + y) % STRIPE_PERIOD < STRIPE_PERIOD / 2 ? red : white;

		Marshal.Copy(pixels, 0, bits, pixelCount);

		return bitmap;
	}

	private void DestroyStripBitmaps()
	{
		if (_horizontalDc != IntPtr.Zero)
		{
			SelectObject(_horizontalDc, _horizontalOldBitmap);
			DeleteDC(_horizontalDc);
			_horizontalDc = IntPtr.Zero;
		}

		if (_horizontalBitmap != IntPtr.Zero)
		{
			DeleteObject(_horizontalBitmap);
			_horizontalBitmap = IntPtr.Zero;
		}

		if (_verticalDc != IntPtr.Zero)
		{
			SelectObject(_verticalDc, _verticalOldBitmap);
			DeleteDC(_verticalDc);
			_verticalDc = IntPtr.Zero;
		}

		if (_verticalBitmap != IntPtr.Zero)
		{
			DeleteObject(_verticalBitmap);
			_verticalBitmap = IntPtr.Zero;
		}
	}

	// ------------------------------------------------------------------
	// Window class
	// ------------------------------------------------------------------

	private static void EnsureClassRegistered(IntPtr instance)
	{
		if (_sClassAtom != 0)
			return;

		var wc = new WNDCLASSEXW
		{
			// layered content only; never erased
			CbSize = (uint)Marshal.SizeOf<WNDCLASSEXW>(),
			Style = 0,
			LpfnWndProc = Marshal.GetFunctionPointerForDelegate(_sWndProc),
			HInstance = instance,
			HbrBackground = IntPtr.Zero,
			LpszClassName = CLASS_NAME,
		};

		_sClassAtom = RegisterClassExW(ref wc);
		if (_sClassAtom == 0)
			throw new InvalidOperationException("RegisterClassEx failed for the overlay class: " + Marshal.GetLastWin32Error());
	}

	private static IntPtr OverlayWndProc(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam)
	{
		switch (msg)
		{
			// Belt and braces alongside WS_EX_TRANSPARENT / WS_EX_NOACTIVATE:
			// the overlay must never take a click and must never activate.
			case WM_NCHITTEST:
				return new IntPtr(HTTRANSPARENT);

			case WM_MOUSEACTIVATE:
				return new IntPtr(MA_NOACTIVATE);

			case WM_ERASEBKGND:
				return new IntPtr(1);
		}
		return DefWindowProcW(hwnd, msg, wParam, lParam);
	}

	private static RECT Rect(int left, int top, int right, int bottom) => new() { Left = left, Top = top, Right = right, Bottom = bottom };

	public void Dispose()
	{
		if (_disposed)
			return;

		_disposed = true;

		for (var i = 0; i < _edges.Length; i++)
			if (_edges[i] != IntPtr.Zero)
			{
				DestroyWindow(_edges[i]);
				_edges[i] = IntPtr.Zero;
			}

		DestroyStripBitmaps();

		if (_sClassAtom != 0)
		{
			UnregisterClassW(CLASS_NAME, GetModuleHandleW(null));
			_sClassAtom = 0;
		}
	}
}
