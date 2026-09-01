using Microsoft.Win32;
using static ActiveBorder.NativeMethods;

namespace ActiveBorder;

/**
 * The Windows personalisation accent colour, as an opaque 0xAARRGGBB.
 *
 * Read from the registry rather than through WinRT. `UISettings.GetColorValue`
 * is the documented route, but it needs a Windows-SDK target framework and the
 * C#/WinRT projections, and this project deliberately has no package
 * references and restores offline.
 *
 * `AccentColorMenu` is the swatch shown in Settings > Personalization >
 * Colors, stored as 0xAABBGGRR. It is written whether the accent is picked by
 * hand or derived automatically from the wallpaper, and it matches entry 3 of
 * the accent palette, which is the base accent shade.
 *
 * `DwmGetColorizationColor` is the documented fallback, but it returns the
 * *composed* colour - the accent already blended with the colorization
 * balance - so it lands a shade or two off the swatch. It is only used when
 * the registry value is missing.
 */
internal static class AccentColor
{
	/** Windows' own default accent, for when nothing at all can be read. */
	internal const uint FALLBACK = 0xFF0078D4;

	private const string ACCENT_KEY = @"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent";
	private const string ACCENT_VALUE = "AccentColorMenu";

	private static uint _current = Read();

	/** The colour as of the last read. */
	internal static uint Current => _current;

	/**
	 * Re-read from the system and return the result.
	 *
	 * Deliberately not a "has it changed?" call: the overlay and the tray
	 * icon are told about a colour change independently and either may get
	 * here first, so each compares this against the colour it last drew with
	 * rather than relying on a one-shot flag.
	 */
	internal static uint Reload() => _current = Read();

	private static uint Read()
	{
		if (Registry.GetValue(ACCENT_KEY, ACCENT_VALUE, null) is int abgr)
			return Opaque(SwapRedAndBlue(unchecked((uint)abgr)));

		if (DwmGetColorizationColor(out var argb, out _) == 0)
			return Opaque(argb);

		return FALLBACK;
	}

	/** 0xAABBGGRR -> 0xAARRGGBB. */
	private static uint SwapRedAndBlue(uint color) => (color & 0xFF00FF00u) | ((color & 0x00FF0000u) >> 16) | ((color & 0x000000FFu) << 16);

	/**
	 * Force full alpha. The border is solid, and at 0xFF the premultiplied
	 * channels equal the straight ones, which is what the layered blend
	 * needs.
	 */
	private static uint Opaque(uint color) => color | 0xFF000000u;
}
