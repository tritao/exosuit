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
	public static inline final WORKBENCH_TEXT_SIZE:Float = 14.0;
	/** Copies every token in place. Reflect.setField on a struct-valued field crashes (see docs/haxeon-compiler-bugs.md), so the list is explicit: add new ThemeTokens fields here. */
	public static function copyTokens(from:haxeon.ui.theme.ThemeTokens, to:haxeon.ui.theme.ThemeTokens):Void {
		to.accent = from.accent; to.text = from.text; to.mutedText = from.mutedText; to.disabledText = from.disabledText;
		to.buttonText = from.buttonText; to.disabledButtonText = from.disabledButtonText;
		to.buttonBackground = from.buttonBackground; to.buttonHover = from.buttonHover; to.buttonPressed = from.buttonPressed;
		to.buttonFocused = from.buttonFocused; to.buttonSelected = from.buttonSelected; to.buttonDisabled = from.buttonDisabled;
		to.navigationBackground = from.navigationBackground; to.navigationHover = from.navigationHover;
		to.navigationPressed = from.navigationPressed; to.navigationFocused = from.navigationFocused;
		to.navigationSelected = from.navigationSelected; to.navigationDisabled = from.navigationDisabled;
		to.controlSelected = from.controlSelected; to.controlUnselected = from.controlUnselected;
		to.controlDisabled = from.controlDisabled; to.progressTrack = from.progressTrack; to.progressFill = from.progressFill;
		to.selectionField = from.selectionField; to.selectionHover = from.selectionHover;
		to.selectionPressed = from.selectionPressed; to.selectionHighlight = from.selectionHighlight;
		to.selectionBorder = from.selectionBorder; to.selectionPopupShadow = from.selectionPopupShadow;
		to.panelBackground = from.panelBackground; to.overlayBackdrop = from.overlayBackdrop;
		to.tooltipBackground = from.tooltipBackground; to.tooltipFontSize = from.tooltipFontSize;
		to.tabHeaderHeight = from.tabHeaderHeight; to.tabHeaderFontSize = from.tabHeaderFontSize;
		to.radiusSmall = from.radiusSmall; to.radiusMedium = from.radiusMedium; to.radiusLarge = from.radiusLarge;
		to.spacingSmall = from.spacingSmall; to.spacingMedium = from.spacingMedium; to.spacingLarge = from.spacingLarge;
		to.accentHover = from.accentHover; to.accentPressed = from.accentPressed;
		to.textPrimary = from.textPrimary; to.textSecondary = from.textSecondary; to.textDisabled = from.textDisabled;
		to.textOnAccent = from.textOnAccent; to.surface = from.surface; to.surfaceRaised = from.surfaceRaised;
		to.surfaceSunken = from.surfaceSunken; to.surfaceHover = from.surfaceHover; to.border = from.border;
		to.borderStrong = from.borderStrong; to.focusRing = from.focusRing; to.info = from.info; to.success = from.success;
		to.warning = from.warning; to.danger = from.danger; to.selection = from.selection;
	}

	public static function theme(dark:Bool, ?target:Theme):Theme {
		var result = dark ? Theme.dark() : Theme.light();
		if (target != null) {
			copyTokens(result.tokens, target.tokens);
			target.textSelectionInactive = result.textSelectionInactive;
			target.body = result.body;
			target.heading = result.heading;
			target.label = result.label;
			target.caption = result.caption;
			target.button = result.button;
			result = target;
		}
		var tokens = result.tokens;
		// Compact workbench chrome leaves content as the visual focus.
		tokens.tabHeaderFontSize = 13.0;
		tokens.radiusSmall = 3.0;
		tokens.radiusMedium = 5.0;
		tokens.radiusLarge = 8.0;
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
		applyWorkbenchRules(result.styles, tokens, dark);
		return result;
	}

	/** Application rules survive UiContext's theme refresh and are rebuilt on theme switches. */
	public static function styleSheet(theme:Theme, dark:Bool):haxeon.ui.style.StyleSheet {
		var sheet = new haxeon.ui.style.StyleSheet("exosuit-workbench");
		applyWorkbenchRules(sheet, theme.tokens, dark);
		return sheet;
	}

	static function applyWorkbenchRules(sheet:haxeon.ui.style.StyleSheet, tokens:haxeon.ui.theme.ThemeTokens, dark:Bool):Void {
		sheet.rule(StyleSelector.widget("split-divider"), [
			StyleValue.background(hex(dark ? WorkbenchColors.darkDivider : WorkbenchColors.lightDivider))
		]);

		// Chrome actions stay quiet until hovered or selected; focus keeps the framework outline.
		var transparent = Color.rgba(0, 0, 0, 0);
		sheet.rule(StyleSelector.widget("button").className("chrome-action"), [StyleValue.background(transparent)]);
		sheet.rule(StyleSelector.widget("button").className("chrome-action").state(StyleState.Hovered), [StyleValue.background(tokens.surfaceHover)]);
		sheet.rule(StyleSelector.widget("button").className("chrome-action").state(StyleState.Pressed), [StyleValue.background(tokens.surfaceSunken)]);
		sheet.rule(StyleSelector.widget("button").className("navigation").className("chrome-action").state(StyleState.Selected), [StyleValue.background(tokens.surfaceHover)]);
		sheet.rule(StyleSelector.widget("button").className("chrome-action").state(StyleState.Disabled), [StyleValue.background(transparent)]);

		sheet.rule(StyleSelector.widget("selection-popup"), [
			StyleValue.borderColor(tokens.border),
			StyleValue.decorations(WorkbenchElevation.surface(dark, 2))
		]);

		// Selected tabs connect visually to the editor canvas.
		sheet.rule(StyleSelector.widget("button").className("tab-header").state(StyleState.Selected), [
			StyleValue.background(hex(dark ? WorkbenchColors.darkEditorBackground : WorkbenchColors.lightEditorBackground))
		]);
		// Soften toolbar hover surfaces without changing their hit targets.
		sheet.rule(StyleSelector.widget("button").className("viewport-tool"), [
			StyleValue.radius(StyleProperty.RadiusTopLeft, tokens.radiusSmall),
			StyleValue.radius(StyleProperty.RadiusTopRight, tokens.radiusSmall),
			StyleValue.radius(StyleProperty.RadiusBottomLeft, tokens.radiusSmall),
			StyleValue.radius(StyleProperty.RadiusBottomRight, tokens.radiusSmall)
		]);

		// Status actions meet the window edge: explicit zero radii override button defaults.
		sheet.rule(StyleSelector.widget("button").className("status-remote"), [
			StyleValue.background(tokens.surfaceRaised),
			StyleValue.radius(StyleProperty.RadiusTopLeft, 0),
			StyleValue.radius(StyleProperty.RadiusTopRight, 0),
			StyleValue.radius(StyleProperty.RadiusBottomLeft, 0),
			StyleValue.radius(StyleProperty.RadiusBottomRight, 0)
		]);
		sheet.rule(StyleSelector.widget("button").className("status-remote").state(StyleState.Hovered),
			[StyleValue.background(tokens.surfaceHover)]);
		sheet.rule(StyleSelector.widget("button").className("status-remote").state(StyleState.Pressed),
			[StyleValue.background(tokens.surfaceSunken)]);
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
		result.divider = WorkbenchColors.opaque(WorkbenchColors.lightDivider);
		result.foregroundMuted = WorkbenchColors.opaque(WorkbenchColors.lightForegroundMuted);
		result.foregroundSubtle = WorkbenchColors.opaque(WorkbenchColors.lightForegroundDisabled);
		result.foregroundDisabled = WorkbenchColors.opaque(WorkbenchColors.lightForegroundDisabled);
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
