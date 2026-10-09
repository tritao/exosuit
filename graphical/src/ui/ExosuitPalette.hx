package ui;

import haxeon.ui.Color;
import style.WorkbenchColors;
import haxeon.ui.theme.Theme;
import haxeon.ui.style.StyleSelector;
import haxeon.ui.style.StyleValue;
import haxeon.ui.style.StyleProperty;
import haxeon.ui.style.StyleState;

/** Shared workbench colors. Keep terminal defaults and chrome in one scheme. */
class ExosuitPalette {
	public static function theme(dark:Bool, ?target:Theme):Theme {
		var result = dark ? Theme.dark() : Theme.light();
		if (target != null) {
			for (field in Reflect.fields(result.tokens))
				Reflect.setField(target.tokens, field, Reflect.field(result.tokens, field));
			target.textSelectionInactive = result.textSelectionInactive;
			target.body = result.body;
			target.heading = result.heading;
			target.label = result.label;
			target.caption = result.caption;
			target.button = result.button;
			result = target;
		}
		var tokens = result.tokens;
		tokens.accent = hex(dark ? WorkbenchColors.darkAccent : WorkbenchColors.lightAccent);
		tokens.accentHover = hex(dark ? WorkbenchColors.darkAccentHover : WorkbenchColors.lightAccentHover);
		tokens.accentPressed = hex(dark ? WorkbenchColors.darkAccentPressed : WorkbenchColors.lightAccentPressed);
		tokens.textPrimary = hex(dark ? WorkbenchColors.darkForeground : WorkbenchColors.lightForeground);
		tokens.textSecondary = hex(dark ? WorkbenchColors.darkForegroundMuted : WorkbenchColors.lightForegroundMuted);
		tokens.textDisabled = hex(dark ? WorkbenchColors.darkForegroundDisabled : WorkbenchColors.lightForegroundDisabled);
		tokens.textOnAccent = hex(dark ? WorkbenchColors.darkForegroundOnAccent : WorkbenchColors.lightForegroundOnAccent);
		tokens.surface = hex(dark ? WorkbenchColors.darkSurface : WorkbenchColors.lightSurface);
		tokens.surfaceRaised = hex(dark ? WorkbenchColors.darkSurfaceRaised : WorkbenchColors.lightSurfaceRaised);
		tokens.surfaceSunken = hex(dark ? WorkbenchColors.darkSurfaceSunken : WorkbenchColors.lightSurfaceSunken);
		tokens.surfaceHover = hex(dark ? WorkbenchColors.darkSurfaceHover : WorkbenchColors.lightSurfaceHover);
		tokens.border = hex(dark ? WorkbenchColors.darkBorder : WorkbenchColors.lightBorder);
		tokens.borderStrong = hex(dark ? WorkbenchColors.darkBorderStrong : WorkbenchColors.lightBorderStrong);
		tokens.focusRing = hex(dark ? WorkbenchColors.darkAccentHover : WorkbenchColors.lightAccent);
		tokens.selection = hex(dark ? WorkbenchColors.darkSelection : WorkbenchColors.lightSelection);
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
		result.editorBackground = WorkbenchColors.opaque(WorkbenchColors.lightEditorBackground);
		result.editorForeground = WorkbenchColors.opaque(WorkbenchColors.lightForeground);
		result.surface = WorkbenchColors.opaque(WorkbenchColors.lightEditorSurface);
		result.surfaceElevated = WorkbenchColors.opaque(WorkbenchColors.lightSurfaceRaised);
		result.surfaceActive = WorkbenchColors.opaque(WorkbenchColors.lightSurfaceHover);
		result.surfaceInactive = WorkbenchColors.opaque(WorkbenchColors.lightEditorInactive);
		result.surfaceHover = WorkbenchColors.opaque(WorkbenchColors.lightEditorHover);
		result.border = WorkbenchColors.opaque(WorkbenchColors.lightBorder);
		result.divider = WorkbenchColors.opaque(WorkbenchColors.lightBorder);
		result.foregroundMuted = WorkbenchColors.opaque(WorkbenchColors.lightForegroundMuted);
		result.foregroundSubtle = WorkbenchColors.opaque(WorkbenchColors.lightForegroundDisabled);
		result.caret = WorkbenchColors.opaque(WorkbenchColors.lightForeground);
		result.currentLine = WorkbenchColors.opaque(WorkbenchColors.lightCurrentLine);
		result.selection = WorkbenchColors.opaque(WorkbenchColors.lightSelection);
		result.searchMatch = WorkbenchColors.opaque(WorkbenchColors.lightSearchMatch);
		result.bracketMatch = WorkbenchColors.opaque(WorkbenchColors.lightBracketMatch);
		result.accent = WorkbenchColors.opaque(WorkbenchColors.lightAccent);
		result.lightSyntax = true;
		return result;
	}

	public static function hex(rgb:Int):Color
		return Color.fromBytes((rgb >>> 16) & 255, (rgb >>> 8) & 255, rgb & 255);
}
