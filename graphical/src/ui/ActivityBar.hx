package ui;

import haxeon.ui.Rect;

import haxeon.ui.Insets;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.TextWrap;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.TextStyleOverride;
import haxeon.ui.core.View;
import haxeon.ui.icons.IconName;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.controls.Button;
import haxeon.ui.widgets.controls.ButtonVariant;
import haxeon.ui.widgets.layout.Column;
import haxeon.ui.widgets.sidebar.SidebarModel;
import haxeon.ui.widgets.text.Text;

/** Destinations come from the sidebar registry; selection stays in its model. */
class ActivityBar implements View {
	public static inline final WIDTH = 56.0;
	final model:SidebarModel;
	final icons:Map<String, IconName>;
	final activate:String->Void;
	final tooltipDelay:Float;
	public function new(model:SidebarModel, icons:Map<String, IconName>, activate:String->Void, tooltipDelay:Float) {
		this.model = model; this.icons = icons; this.activate = activate; this.tooltipDelay = tooltipDelay;
	}
	public function build(context:BuildContext):RenderNode {
		var style = new LayoutStyle();
		style.width = LayoutAxis.fixed(WIDTH);
		style.height = LayoutAxis.grow();
		style.padding = new Insets(8, 8, 8, 8);
		style.childGap = 6;
		style.background = context.theme.tokens.surfaceRaised;
		var items:Array<KeyedView> = [];
		for (mode in model.modes) {
			if (!mode.visible) continue;
			var id = mode.id;
			var buttonStyle = new LayoutStyle();
			buttonStyle.width = LayoutAxis.fixed(40);
			buttonStyle.height = LayoutAxis.fixed(40);
			var button = new Button("", buttonStyle, function() activate(id), "activity:" + id);
			button.variant = ButtonVariant.Navigation;
			button.leadingIcon = icons.exists(id) ? icons.get(id) : IconName.FolderOpen;
			button.iconSize = 20;
			button.accessibilityLabel = mode.label;
			button.selected = model.visible && model.activeId == id;
			items.push(new KeyedView(id, new TabTooltip("activity-tooltip:" + id, button,
				new Text(mode.label, null, context.theme.tokens.textPrimary, new TextStyleOverride(null, 13, null, TextWrap.None)),
				function() return new Rect(0, 0, context.viewportWidth, context.viewportHeight), tooltipDelay, true)));
		}
		return new Column("activity-bar", items, style).build(context);
	}
}
