using System.Globalization;

namespace ActiveBorder;

/**
 * Appearance, read once from the environment when the process starts.
 *
 *   AB_COLOR_1   first stripe colour, RRGGBB hex   default FF0000 (red)
 *   AB_COLOR_2    second stripe colour, RRGGBB hex  default FFFFFF (white)
 *   AB_WIDTH     border thickness in physical px   default 5, range 1..64
 *
 * Anything missing, malformed or out of range silently falls back to its
 * default. This is a tray utility with no console and no settings UI, so it
 * has nowhere to report a bad value, and refusing to start over one typo
 * would be far worse than ignoring it.
 *
 * The values are fixed for the lifetime of the process: the strip bitmaps are
 * rendered once at start-up from them, so changing an environment variable
 * takes effect the next time the utility runs.
 */
internal static class Settings
{
	internal const uint DEFAULT_COLOR_1 = 0xFFFF0000;   // red   #FF0000
	internal const uint DEFAULT_COLOR_2 = 0xFFFFFFFF;   // white #FFFFFF
	internal const int DEFAULT_WIDTH = 5;

	/**
	 * The strips are as long as the virtual screen, so their bitmaps grow
	 * linearly with the thickness. A wider border than this is a typo rather
	 * than an intention, and would allocate tens of megabytes.
	 */
	internal const int MAX_WIDTH = 64;

	internal static readonly uint Color1 = ReadColor("AB_COLOR_1", DEFAULT_COLOR_1);
	internal static readonly uint Color2 = ReadColor("AB_COLOR_2", DEFAULT_COLOR_2);
	internal static readonly int Width = ReadWidth("AB_WIDTH", DEFAULT_WIDTH);

	/**
	 * Parse RRGGBB into an opaque 0xAARRGGBB. A leading # is tolerated because
	 * it is the form everyone types. At full alpha the premultiplied channels
	 * equal the straight ones, which is what the layered blend needs.
	 */
	private static uint ReadColor(string name, uint fallback)
	{
		var raw = Environment.GetEnvironmentVariable(name);
		if (string.IsNullOrWhiteSpace(raw))
			return fallback;

		var text = raw.Trim();
		if (text.StartsWith('#'))
			text = text[1..];

		if (text.Length != 6)
			return fallback;

		if (!uint.TryParse(text, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var rgb))
			return fallback;

		return 0xFF000000u | rgb;
	}

	private static int ReadWidth(string name, int fallback)
	{
		var raw = Environment.GetEnvironmentVariable(name);
		if (string.IsNullOrWhiteSpace(raw))
			return fallback;

		if (!int.TryParse(raw.Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out var width))
			return fallback;

		if (width < 1 || width > MAX_WIDTH)
			return fallback;

		return width;
	}
}
