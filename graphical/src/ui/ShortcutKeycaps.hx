package ui;

import haxeon.ui.Color;
import haxeon.ui.Insets;
import haxeon.ui.LayoutAlignmentY;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.Rect;
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
					var label = switch key.toLowerCase() {
						case "up": "UpArrow";
						case "down": "DownArrow";
						case "left": "LeftArrow";
						case "right": "RightArrow";
						default: key;
					};
					caps.push(new KeyedView("key-" + caps.length, new ShortcutKeycap(label, selected)));
				}
				var chordStyle = new LayoutStyle();
				chordStyle.childGap = 3.0;
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
		style.height = LayoutAxis.fixed(22.0);
		style.padding = new Insets(5.0, 1.0, 5.0, 2.0);
		style.background = selected ? Color.rgba(1.0, 1.0, 1.0, 0.14) : tokens.surfaceRaised;
		style.radiusTopLeft = style.radiusTopRight = style.radiusBottomLeft = style.radiusBottomRight = 3.0;
		var node = new Row("keycap", [new KeyedView("label", new Text(label, null,
			selected ? tokens.textOnAccent : tokens.textPrimary, TextStyleOverride.text(12.0)))], style).build(context);
		var borderStyle = new LayoutStyle(); borderStyle.width = LayoutAxis.grow(); borderStyle.height = LayoutAxis.grow();
		borderStyle.positioning = haxeon.ui.LayoutPositioning.Absolute;
		var borderNode = new RenderNode(context.id("keycap-border"), haxeon.ui.LayoutVisualKind.Custom, borderStyle);
		borderNode.hitTestSelf = false;
		var border = selected ? Color.rgba(1.0, 1.0, 1.0, 0.4) : tokens.border;
		borderNode.onPaint(function(canvas, geometry) {
			canvas.fillRectIfPositive(new Rect(2, 0, geometry.width - 4, 1), border);
			canvas.fillRectIfPositive(new Rect(2, geometry.height - 2, geometry.width - 4, 2), border);
			canvas.fillRectIfPositive(new Rect(0, 2, 1, geometry.height - 4), border);
			canvas.fillRectIfPositive(new Rect(geometry.width - 1, 2, 1, geometry.height - 4), border);
		});
		node.add(borderNode);
		node.hitTestSelf = false;
		return node;
	}
}
