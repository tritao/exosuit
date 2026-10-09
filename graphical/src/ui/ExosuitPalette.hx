package ui;

import haxeon.ui.Color;
import haxeon.ui.theme.Theme;
import haxeon.ui.style.StyleSelector;
import haxeon.ui.style.StyleValue;
import haxeon.ui.style.StyleProperty;
import haxeon.ui.style.StyleState;

/** Shared workbench colors. Keep terminal defaults and chrome in one scheme. */
class ExosuitPalette {
	public static function theme(dark:Bool):Theme {
		var result = dark ? Theme.dark() : Theme.light();
		var tokens = result.tokens;
		tokens.accent = hex(dark ? 0x78aef8 : 0x2866b2);
		tokens.accentHover = hex(dark ? 0x91bfff : 0x1d579d);
		tokens.accentPressed = hex(dark ? 0x5e96df : 0x18477f);
		tokens.textPrimary = hex(dark ? 0xdce3ec : 0x202a36);
		tokens.textSecondary = hex(dark ? 0xa6b2c1 : 0x536174);
		tokens.textDisabled = hex(dark ? 0x8793a3 : 0x687589);
		tokens.textOnAccent = hex(dark ? 0x14202e : 0xffffff);
		tokens.surface = hex(dark ? 0x202630 : 0xf4f6fa);
		tokens.surfaceRaised = hex(dark ? 0x262e39 : 0xe8edf4);
		tokens.surfaceSunken = hex(dark ? 0x171c23 : 0xffffff);
		tokens.surfaceHover = hex(dark ? 0x303b49 : 0xdce5f1);
		tokens.border = hex(dark ? 0x526071 : 0x8b9aad);
		tokens.borderStrong = hex(dark ? 0x657489 : 0x718299);
		tokens.focusRing = hex(dark ? 0x91bfff : 0x2866b2);
		tokens.selection = hex(dark ? 0x294765 : 0xc6dcf6);
		tokens.deriveComponents();
		result.textSelection = Color.rgba(dark ? 0.23 : 0.38,
			dark ? 0.47 : 0.63, dark ? 0.76 : 0.89, dark ? 0.65 : 0.50);
		result.textCaret = tokens.textPrimary;
		result.refreshStyles();
		// Status actions meet the window edge: explicit zero radii override button defaults.
		result.styles.rule(StyleSelector.widget("button").className("status-remote"), [
			StyleValue.background(tokens.surfaceRaised),
			StyleValue.radius(StyleProperty.RadiusTopLeft, 0),
			StyleValue.radius(StyleProperty.RadiusTopRight, 0),
			StyleValue.radius(StyleProperty.RadiusBottomLeft, 0),
			StyleValue.radius(StyleProperty.RadiusBottomRight, 0)
		]);
		result.styles.rule(StyleSelector.widget("button").className("status-remote").state(StyleState.Hovered),
			[StyleValue.background(tokens.surfaceHover)]);
		result.styles.rule(StyleSelector.widget("button").className("status-remote").state(StyleState.Pressed),
			[StyleValue.background(tokens.surfaceSunken)]);
		return result;
	}

	public static function lightEditor():style.Theme {
		var result = new style.Theme();
		result.editorBackground = 0xffffffff;
		result.editorForeground = 0x202a36ff;
		result.surface = 0xf0f4f9ff;
		result.surfaceElevated = 0xe8edf4ff;
		result.surfaceActive = 0xdce5f1ff;
		result.surfaceInactive = 0xf4f6faff;
		result.surfaceHover = 0xe5ecf5ff;
		result.border = 0x8b9aadff;
		result.divider = 0x8b9aadff;
		result.foregroundMuted = 0x536174ff;
		result.foregroundSubtle = 0x687589ff;
		result.caret = 0x202a36ff;
		result.currentLine = 0xf1f5faff;
		result.selection = 0xc6dcf6ff;
		result.searchMatch = 0xffe7a0ff;
		result.bracketMatch = 0xd7e5f6ff;
		result.accent = 0x2866b2ff;
		result.lightSyntax = true;
		return result;
	}

	public static function hex(rgb:Int):Color
		return Color.fromBytes((rgb >>> 16) & 255, (rgb >>> 8) & 255, rgb & 255);
}
