package app;

import haxeon.ui.Color;
import haxeon.ui.style.StyleResolver;
import haxeon.ui.style.StyleTarget;
import haxeon.ui.style.StyleState;
import haxeon.ui.style.StyleProperty;
import haxeon.ui.theme.Theme;
import ui.ExosuitPalette;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.StateStore;
import haxeon.ui.widgets.controls.Button;
import haxeon.ui.widgets.controls.ButtonVariant;

class ButtonThemeTestMain {
	static function require(value:Bool, message:String):Void { if (!value) throw message; }
	static function main():Int {
		var editor = new style.Theme(), settings = new config.Settings();
		require(editor.editorBackground == settings.editorBackground && editor.editorForeground == settings.editorForeground,
			"Settings and editor theme have different default colors");
		require(style.Theme.contrastRatio(editor.editorBackground, editor.editorForeground) >= 7,
			"Default dark editor text lacks contrast");
		for (field in ["accent", "surface", "surfaceElevated", "surfaceActive", "surfaceInactive", "surfaceHover",
			"border", "divider", "foregroundMuted", "foregroundSubtle", "foregroundDisabled", "selection"])
			require(Reflect.field(editor, field) == Reflect.field(settings, field), "Mismatched default " + field);
		for (dark in [true, false]) {
			var palette = ExosuitPalette.theme(dark);
			var t = palette.tokens;
			for (surface in [t.surface, t.surfaceRaised]) {
				require(Theme.contrastRatio(t.textPrimary, surface) >= 4.5, "Primary text lacks contrast");
				require(Theme.contrastRatio(t.textSecondary, surface) >= 4.5, "Secondary text lacks contrast");
			}
			require(Theme.contrastRatio(t.textOnAccent, t.accent) >= 4.5, "Accent label lacks contrast");
			var tab = new StyleResolver().resolve(new StyleTarget("button", "tab", "tab", ["tab-header"], ["button"], StyleState.Selected), null, palette.styles);
			var fill = tab.get(StyleProperty.Background);
			var expected = ExosuitPalette.hex(dark ? style.WorkbenchColors.darkEditorBackground : style.WorkbenchColors.lightEditorBackground);
			require(fill.red == expected.red && fill.green == expected.green && fill.blue == expected.blue,
				"Selected tab does not match editor canvas");
			var resolver = new StyleResolver();
			var quiet = resolver.resolve(new StyleTarget("button", "chrome", "chrome", ["navigation", "chrome-action"], ["button"], 0), null, palette.styles);
			var hovered = resolver.resolve(new StyleTarget("button", "chrome", "chrome", ["navigation", "chrome-action"], ["button"], StyleState.Hovered), null, palette.styles);
			var selectedChrome = resolver.resolve(new StyleTarget("button", "chrome", "chrome", ["navigation", "chrome-action"], ["button"], StyleState.Selected), null, palette.styles);
			var focused = resolver.resolve(new StyleTarget("button", "chrome", "chrome", ["navigation", "chrome-action"], ["button"], StyleState.Focused), null, palette.styles);
			require(quiet.get(StyleProperty.Background).alpha == 0 && hovered.get(StyleProperty.Background).alpha > 0,
				"Chrome action must be quiet until hovered");
			require(focused.get(StyleProperty.BorderWidth) > 0, "Chrome action lost keyboard focus outline");
			var selectedFill = selectedChrome.get(StyleProperty.Background);
			require(selectedFill.red == t.surfaceHover.red && selectedFill.green == t.surfaceHover.green && selectedFill.blue == t.surfaceHover.blue,
				"Chrome selection should use a neutral surface");
			var popup = resolver.resolve(new StyleTarget("selection-popup", "options", "options", null, ["selection-popup"], 0), null, palette.styles);
			require(popup.get(StyleProperty.Decorations).decorations.length > 0, "Selection popup lost elevation");
		}
		var live = ExosuitPalette.theme(false);
		var liveFonts = haxeon.ui.FontCollection.create();
		liveFonts.add("../../haxeon/packages/ui/vendor/skribidi/example/data/IBMPlexSans-Regular.ttf");
		var liveContext = new haxeon.ui.core.UiContext(null, liveFonts, live);
		for (dark in [false, true, false]) {
			ExosuitPalette.theme(dark, live);
			liveContext.setTheme(live);
			liveContext.setStyleSheet(ExosuitPalette.styleSheet(live, dark));
			var chrome = new Button("Action", null, function() {}, "live-chrome");
			chrome.variant = ButtonVariant.Navigation; chrome.classes.push("chrome-action"); chrome.selected = true;
			var node = liveContext.submit(chrome, new haxeon.ui.LayoutFrame(200, 80));
			var background = node.computedStyle.get(StyleProperty.Background);
			require(background.red == live.tokens.surfaceHover.red && background.green == live.tokens.surfaceHover.green
				&& background.blue == live.tokens.surfaceHover.blue, "Live theme refresh lost chrome selection styling");
		}
		liveContext.dispose();
		liveFonts.dispose();
		var tokens = live.tokens;
		var styles = live.styles;
		for (dark in [true, false, true]) {
			var expected = ExosuitPalette.theme(dark);
			require(ExosuitPalette.theme(dark, live) == live && live.tokens == tokens && live.styles == styles,
				"Theme switching replaced shared objects");
			require(live.tokens.surface.red == expected.tokens.surface.red
				&& live.tokens.textPrimary.red == expected.tokens.textPrimary.red
				&& live.textCaret.red == expected.textCaret.red, "Theme switching retained old colors");
		}
		var terminal = new ui.TerminalPalette(false);
		terminal.fontSize = 18;
		for (dark in [true, false]) {
			terminal.setDark(dark);
			var expected = new ui.TerminalPalette(dark);
			require(terminal.background.red == expected.background.red && terminal.foreground.red == expected.foreground.red
				&& terminal.ansi[0].red == expected.ansi[0].red && terminal.fontSize == 18,
				"Terminal theme switching retained old colors or changed font size");
		}
		var states = [0, StyleState.Hovered, StyleState.Pressed, StyleState.Focused,
			StyleState.Selected, StyleState.Focused | StyleState.Hovered,
			StyleState.Selected | StyleState.Focused, StyleState.Disabled];
		var count = 0;
		for (theme in [Theme.light(), Theme.dark(), ExosuitPalette.theme(false), ExosuitPalette.theme(true)]) {
			var resolver = new StyleResolver();
			for (variant in ["primary", "secondary", "navigation"]) {
				var classes = variant == "primary" ? [] : [variant];
				var context = new BuildContext(new StateStore(), null, null, null, theme);
				var button = new Button("Probe", null, function() {}, "actual-button");
				button.variant = variant == "primary" ? ButtonVariant.Primary : variant == "secondary" ? ButtonVariant.Secondary : ButtonVariant.Navigation;
				context.beginFrame();
				var buttonId = button.build(context).id;
				var normal = resolver.resolve(new StyleTarget("button", "normal", "normal", classes, ["button"], 0), null, theme.styles);
				for (state in states) {
					var computed = resolver.resolve(new StyleTarget("button", "probe", "probe", classes, ["button"], state), null, theme.styles);
					var background = computed.get(StyleProperty.Background);
					var disabled = state == StyleState.Disabled;
					var foreground = theme.buttonLabelColor(!disabled, background,
						variant == "primary" ? theme.tokens.textOnAccent : theme.tokens.textPrimary);
					if (!disabled) require(Theme.contrastRatio(foreground, background) >= 4.5,
						variant + " state " + state + " has unreadable foreground");
					if (state == StyleState.Focused) {
						var base = normal.get(StyleProperty.Background);
						require(background.red == base.red && background.green == base.green && background.blue == base.blue && background.alpha == base.alpha, "Focus replaced " + variant + " background");
						require(computed.get(StyleProperty.BorderWidth) > 0,
							"Focus outline is missing for " + variant);
					}
					context.interactionStates.set(buttonId, state);
					context.beginFrame();
					button.enabled = !disabled; button.selected = (state & StyleState.Selected) != 0;
					var actual = button.build(context);
					if (!disabled) require(Theme.contrastRatio(actual.children[0].layout.textColor, actual.layout.style.background) >= 4.5,
						"Button widget ignored foreground contrast for " + variant + " state " + state);
					count++;
				}
			}
			for (fill in [Color.fromBytes(0, 102, 184), Color.fromBytes(240, 240, 240), Color.fromBytes(20, 20, 20)])
				require(Theme.contrastRatio(theme.buttonLabelColor(true, fill, theme.tokens.textPrimary), fill) >= 4.5,
					"Custom button fill has unreadable text");
		}
		Sys.println("PASS: " + count + " button theme/state combinations, focus outlines and custom-fill contrast");
		return 0;
	}
}
