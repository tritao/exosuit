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
