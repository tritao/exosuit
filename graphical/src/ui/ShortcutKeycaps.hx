package ui;

import haxeon.ui.Color;
import haxeon.ui.Insets;
import haxeon.ui.LayoutAlignmentY;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.TextStyleOverride;
import haxeon.ui.core.View;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.layout.Row;
import haxeon.ui.widgets.text.Text;

/** Alternatives use “or”; whitespace separates sequential chords, + joins simultaneous keys. */
class ShortcutKeycaps implements View {
	final shortcut:String;
	final selected:Bool;

	public function new(shortcut:String, selected:Bool) {
		this.shortcut = shortcut;
		this.selected = selected;
	}

	public function build(context:BuildContext):RenderNode {
		var children:Array<KeyedView> = [];
		var color = selected ? context.theme.tokens.textOnAccent : context.theme.tokens.textSecondary;
		for (alternative in shortcut.split(",")) {
			if (children.length > 0) children.push(new KeyedView("or-" + children.length,
				new Text("or", null, color, TextStyleOverride.text(11.0))));
			var chords = ~/\s+/g.split(StringTools.trim(alternative));
			for (chord in chords) {
				if (chord.length == 0) continue;
				var keys = chord.split("+");
				// A literal '+' key is represented by the final empty pair in Ctrl++.
				if (StringTools.endsWith(chord, "++")) { keys.pop(); keys[keys.length - 1] = "+"; }
				var caps:Array<KeyedView> = [];
				for (key in keys) {
					if (key.length == 0) continue;
					if (caps.length > 0) caps.push(new KeyedView("plus-" + caps.length,
						new Text("+", null, color, TextStyleOverride.text(11.0))));
					caps.push(new KeyedView("key-" + caps.length, new ShortcutKeycap(key, selected)));
				}
				var chordStyle = new LayoutStyle();
				chordStyle.childGap = 4.0;
				chordStyle.childAlignY = LayoutAlignmentY.Center;
				children.push(new KeyedView("chord-" + children.length, new Row("shortcut-chord", caps, chordStyle)));
			}
		}
		var style = new LayoutStyle();
		style.childGap = 10.0;
		style.childAlignY = LayoutAlignmentY.Center;
		var node = new Row("shortcut-keycaps", children, style).build(context);
		node.semantics = new haxeon.ui.semantics.Semantics(haxeon.ui.semantics.AccessibilityRole.Text, shortcut);
		node.hitTestSelf = false;
		return node;
	}
}

private class ShortcutKeycap implements View {
	final label:String;
	final selected:Bool;
	public function new(label:String, selected:Bool) { this.label = label; this.selected = selected; }

	public function build(context:BuildContext):RenderNode {
		var tokens = context.theme.tokens;
		var style = new LayoutStyle();
		style.width = LayoutAxis.fit(24.0);
		style.height = LayoutAxis.fixed(24.0);
		style.padding = new Insets(5.0, 0.0, 5.0, 0.0);
		// A Row distributes spare horizontal space through childDistribution.
		style.childDistribution = haxeon.ui.LayoutDistribution.Center;
		style.childAlignY = LayoutAlignmentY.Center;
		var base = selected ? tokens.accent : tokens.surface;
		var ink = selected ? tokens.textOnAccent : tokens.textPrimary;
		style.background = blend(base, ink, selected ? 0.12 : 0.04);
		style.radiusTopLeft = style.radiusTopRight = style.radiusBottomLeft = style.radiusBottomRight = 4.0;
		var arrow:Null<haxeon.ui.icons.IconName> = switch label.toLowerCase() {
			case "up", "uparrow": haxeon.ui.icons.IconName.ArrowUp;
			case "down", "downarrow": haxeon.ui.icons.IconName.ArrowDown;
			case "left", "leftarrow": haxeon.ui.icons.IconName.ArrowLeft;
			case "right", "rightarrow": haxeon.ui.icons.IconName.ArrowRight;
			default: null;
		};
		var foreground = selected ? tokens.textOnAccent : tokens.textSecondary;
		var content:View = arrow == null
			? new Text(label, null, foreground, new TextStyleOverride(null, 12.0, null,
				haxeon.ui.TextWrap.None, haxeon.ui.TextAlignment.Center, 16.0))
			: new haxeon.ui.widgets.Icon("arrow", arrow, 14.0, foreground);
		var node = new Row("keycap", [new KeyedView("label", content)], style).build(context);
		var surfaceStyle = new LayoutStyle();
		surfaceStyle.width = LayoutAxis.grow();
		surfaceStyle.height = LayoutAxis.grow();
		surfaceStyle.positioning = haxeon.ui.LayoutPositioning.Absolute;
		var surface = new RenderNode(context.id("keycap-surface"), haxeon.ui.LayoutVisualKind.Custom, surfaceStyle);
		surface.hitTestSelf = false;
		var border = blend(base, ink, selected ? 0.35 : 0.20);
		surface.onPaint(function(canvas, geometry) {
			if (geometry.width <= 2 || geometry.height <= 3) return;
			canvas.strokeTransient(new haxeon.ui.PathBuilder().roundRect(0.5, 0.5,
				geometry.width - 1, geometry.height - 1, 3.5).build(), border, 1.0);
			canvas.strokeTransient(new haxeon.ui.PathBuilder().moveTo(4, geometry.height - 1.5)
				.lineTo(geometry.width - 4, geometry.height - 1.5).build(), border, 1.0);
		});
		node.add(surface);
		node.hitTestSelf = false;
		return node;
	}

	static function blend(base:Color, ink:Color, amount:Float):Color {
		return Color.rgba(base.red + (ink.red - base.red) * amount,
			base.green + (ink.green - base.green) * amount,
			base.blue + (ink.blue - base.blue) * amount);
	}
}
