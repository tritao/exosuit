package ui;

import haxeon.ui.Rect;
import haxeon.ui.LayoutAxis;
import haxeon.ui.TextAlignment;
import haxeon.ui.TextWrap;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.TextStyleOverride;
import haxeon.ui.core.View;
import haxeon.ui.widgets.text.Text;
import plugin.PluginResourceDecoration;
import plugin.PluginResourceDecorationColor;

/** Compact, theme-backed tree badge whose full description is available on hover. */
class ResourceDecorationBadge implements View {
	final decoration:PluginResourceDecoration;
	final fontSize:Float;

	public function new(decoration:PluginResourceDecoration, fontSize:Float) {
		this.decoration = decoration;
		this.fontSize = fontSize;
	}

	public function build(context:BuildContext):haxeon.ui.core.RenderNode {
		var color = colorFor(decoration, context.theme);
		var anchor = new Text(decoration.badge, null, color,
			new TextStyleOverride(null, fontSize, null, TextWrap.None, TextAlignment.Center));
		var description = decoration.tooltip;
		if (decoration.inherited) description += "\nFrom " + decoration.sourcePath;
		var tooltip = new TabTooltip("resource-decoration:" + decoration.owner + ":" + decoration.id + ":" + decoration.path,
			anchor, new Text(description, null, null,
				new TextStyleOverride(null, 12, null, TextWrap.WordCharacter)),
			function() return new Rect(0, 0, context.viewportWidth, context.viewportHeight), 0.5, Above);
		tooltip.fillAnchor = true;
		var node = tooltip.build(context);
		node.layout.style.width = LayoutAxis.fixed(24.0);
		return node;
	}

	public static function colorFor(decoration:PluginResourceDecoration, theme:haxeon.ui.theme.Theme):haxeon.ui.Color
		return switch decoration.color {
			case Text: theme.tokens.text;
			case Secondary: theme.tokens.textSecondary;
			case Accent: theme.tokens.accent;
			case Success: theme.tokens.success;
			case Warning: theme.tokens.warning;
			case Danger: theme.tokens.danger;
		};
}
