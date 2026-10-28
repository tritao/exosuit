package ui;

import haxeon.ui.widgets.overlays.TooltipHoverGroup;

import haxeon.ui.widgets.overlays.TooltipPlacement;

import haxeon.ui.Rect;

import haxeon.ui.Insets;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.TextWrap;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.TextStyleOverride;
import haxeon.ui.core.View;
import haxeon.ui.core.UiEvent;
import haxeon.ui.core.UiEventKind;
import haxeon.ui.core.UiKey;
import haxeon.ui.Point;
import haxeon.ui.icons.IconName;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.controls.Button;
import haxeon.ui.widgets.controls.ButtonVariant;
import haxeon.ui.widgets.layout.Column;
import haxeon.ui.widgets.sidebar.SidebarModel;
import haxeon.ui.widgets.text.Text;

/** Destinations come from the sidebar registry; selection and order stay in its model.
	Dragging an icon reorders the destinations; a secondary click asks for the rail's menu. */
class ActivityBar implements View {
	public static inline final WIDTH = 56.0;
	/** Opens the rail's menu for a destination, or for the rail itself when the id is null. */
	public var onContextMenu:Null<(Null<String>, UiEvent)->Void> = null;
	final model:SidebarModel;
	final icons:Map<String, IconName>;
	final activate:String->Void;
	final tooltipDelay:Float;
	final manage:UiEvent->Void;
	final manageOpen:Bool;
	public function new(model:SidebarModel, icons:Map<String, IconName>, activate:String->Void, tooltipDelay:Float,
			manage:UiEvent->Void, manageOpen:Bool = false) {
		this.manage = manage;
		this.manageOpen = manageOpen;
		this.model = model; this.icons = icons; this.activate = activate; this.tooltipDelay = tooltipDelay;
	}
	public function build(context:BuildContext):RenderNode {
		var visibleTooltip = context.resourceState(context.id("activity-tooltip-visible"),
			function():Null<String> return null, function(_) {});
		var hover = context.resourceState(context.id("activity-tooltip-hover"),
			function() return new TooltipHoverGroup(context.animations, function(key) visibleTooltip.update(key), tooltipDelay),
			function(value) value.dispose()).value;
		hover.delaySeconds = tooltipDelay;
		var drag = context.resourceState(context.id("activity-drag"),
			function() return new ActivityBarDrag(), function(value) value.dispose()).value;
		drag.items.clear();
		var order:Array<String> = [];
		for (mode in model.modes) if (mode.visible) order.push(mode.id);
		var style = new LayoutStyle();
		style.width = LayoutAxis.fixed(WIDTH);
		style.height = LayoutAxis.grow();
		style.padding = new Insets(0, 8, 0, 8);
		style.childGap = 6;
		style.background = context.theme.tokens.surfaceRaised;
		var items:Array<KeyedView> = [];
		for (mode in model.modes) {
			if (!mode.visible) continue;
			var id = mode.id;
			var index = order.indexOf(id);
			var marker = drag.insertion < 0 ? 0 : drag.insertion == index ? 1 :
				drag.insertion == order.length && index == order.length - 1 ? 2 : 0;
			var buttonStyle = new LayoutStyle();
			buttonStyle.width = LayoutAxis.fixed(40);
			buttonStyle.height = LayoutAxis.fixed(40);
			var button = new Button("", buttonStyle, function() activate(id), "activity:" + id);
			button.variant = ButtonVariant.Navigation;
			button.classes.push("chrome-action");
			button.leadingIcon = icons.exists(id) ? icons.get(id) : IconName.FolderOpen;
			button.iconSize = 20;
			button.accessibilityLabel = mode.label;
			button.selected = model.visible && model.activeId == id;
			items.push(new KeyedView(id, new ActivityBarItem(new TabTooltip("activity-tooltip:" + id, button,
				new Text(mode.label, null, null, TextStyleOverride.paragraph(TextWrap.None)),
				function() return new Rect(0, 0, context.viewportWidth, context.viewportHeight), tooltipDelay, Right,
				hover, visibleTooltip.value == "activity-tooltip:" + id), button.selected, marker,
				function(node) drag.items.set(id, node))));
		}
		items.push(new KeyedView("space", new haxeon.ui.widgets.layout.Spacer("activity-space")));
		var manageStyle = new LayoutStyle();
		manageStyle.width = LayoutAxis.fixed(40);
		manageStyle.height = LayoutAxis.fixed(40);
		var gear = new Button("", manageStyle, null, "activity-manage");
		gear.onClickEvent = function(event) { hover.cancel(); manage(event); };
		gear.variant = ButtonVariant.Navigation;
		gear.classes.push("chrome-action");
		gear.leadingIcon = IconName.Settings;
		gear.iconSize = 22;
		gear.accessibilityLabel = "Manage";
		gear.selected = manageOpen;
		items.push(new KeyedView("manage", new ActivityBarItem(new TabTooltip("activity-tooltip:manage", gear,
			new Text("Manage"),
			function() return new Rect(0, 0, context.viewportWidth, context.viewportHeight), tooltipDelay, Right,
			hover, visibleTooltip.value == "activity-tooltip:manage"), manageOpen, 0, null)));
		var node = new Column("activity-bar", items, style).build(context);
		drag.attach(node, order, model, context, onContextMenu, hover.cancel);
		WorkbenchBoundary.right(context, node);
		return node;
	}
}

/** Full-width slot keeps the selection rail at the bar edge, outside the button. */
private class ActivityBarItem implements View {
	final child:View;
	final selected:Bool;
	/** 0: none, 1: drop line above, 2: drop line below. */
	final marker:Int;
	final built:Null<RenderNode->Void>;
	public function new(child:View, selected:Bool, marker:Int, built:Null<RenderNode->Void>) {
		this.child = child; this.selected = selected; this.marker = marker; this.built = built;
	}
	public function build(context:BuildContext):RenderNode {
		var style = new LayoutStyle();
		style.width = LayoutAxis.fixed(ActivityBar.WIDTH);
		style.height = LayoutAxis.fixed(40);
		style.padding = new Insets(8, 0, 8, 0);
		style.clipToParent = false;
		var node = new haxeon.ui.widgets.layout.Row("activity-item", [new KeyedView("content", child)], style).build(context);
		node.hitTestSelf = false;
		if (selected) {
			var railStyle = new LayoutStyle();
			railStyle.positioning = haxeon.ui.LayoutPositioning.Absolute;
			railStyle.width = LayoutAxis.fixed(2);
			railStyle.height = LayoutAxis.grow();
			railStyle.background = context.theme.tokens.accent;
			var rail = new RenderNode(context.id("activity-selection-rail"), haxeon.ui.LayoutVisualKind.Box, railStyle);
			rail.hitTestSelf = false;
			node.add(rail);
		}
		if (marker != 0) {
			// Centered in the 6 px gap between items.
			var lineStyle = new LayoutStyle();
			lineStyle.positioning = haxeon.ui.LayoutPositioning.Absolute;
			lineStyle.positionX = 8;
			lineStyle.positionY = marker == 1 ? -4 : 42;
			lineStyle.width = LayoutAxis.fixed(40);
			lineStyle.height = LayoutAxis.fixed(2);
			lineStyle.background = context.theme.tokens.accent;
			lineStyle.clipToParent = false;
			var line = new RenderNode(context.id("activity-drop-line"), haxeon.ui.LayoutVisualKind.Box, lineStyle);
			line.hitTestSelf = false;
			node.add(line);
		}
		if (built != null) built(node);
		return node;
	}
}

/** Pointer gesture that reorders the rail; the sidebar model owns the order. */
private class ActivityBarDrag {
	public final items:Map<String, RenderNode> = [];
	/** Visible index the dragged icon would land before, or -1 when the drop would not move it. */
	public var insertion(default, null):Int = -1;
	var order:Array<String> = [];
	var revision:Null<haxeon.ui.core.State<Int>>;
	var source:Null<String>;
	var pointer:Int = -1;
	var startX:Float = 0.0;
	var startY:Float = 0.0;
	var dragging:Bool = false;
	var suppressClick:Bool = false;
	public function new() {}
	public function clear():Void {
		source = null; pointer = -1; dragging = false; insertion = -1;
	}
	public function dispose():Void {
		clear(); items.clear(); revision = null;
	}
	function repaint():Void {
		if (revision != null) revision.update(revision.value + 1);
	}
	function itemAt(x:Float, y:Float):Null<String> {
		var point = new Point(x, y);
		for (id => node in items) if (node.resolved != null && node.containsGlobalPoint(point)) return id;
		return null;
	}
	/** The rail is a column: the icon lands before the first icon whose center is below the pointer. */
	function insertionAt(y:Float):Int {
		var from = source == null ? -1 : order.indexOf(source);
		if (from < 0) return -1;
		var index = 0;
		for (i in 0...order.length) {
			var node = items.get(order[i]);
			if (node == null || node.resolved == null) continue;
			var bounds = node.globalBounds();
			if (y > bounds.y + bounds.height / 2) index = i + 1;
		}
		return index == from || index == from + 1 ? -1 : index;
	}
	public function attach(root:RenderNode, order:Array<String>, model:haxeon.ui.widgets.sidebar.SidebarModel,
			context:BuildContext, menu:Null<(Null<String>, UiEvent)->Void>, started:Void->Void):Void {
		this.order = order;
		revision = context.state(context.id("activity-drag-revision"), 0);
		if (source != null && order.indexOf(source) < 0) clear();
		root.on(UiEventKind.PointerDown, function(event) {
			if (event.button == 1) {
				if (menu == null) return;
				clear();
				menu(itemAt(event.x, event.y), event);
				event.preventDefault(); event.stopPropagation();
				return;
			}
			if (event.button != 0) return;
			clear(); suppressClick = false;
			var id = itemAt(event.x, event.y);
			if (id == null || order.length < 2) return;
			// No pointer capture: the release still reaches the rail through the pressed button's path, and the
			// button's pressed state clears normally.
			source = id; pointer = event.pointerId; startX = event.x; startY = event.y;
		});
		root.on(UiEventKind.PointerMove, function(event) {
			if (source == null || pointer != event.pointerId) return;
			var dx = event.x - startX, dy = event.y - startY;
			if (!dragging && dx * dx + dy * dy < 36) return;
			if (!dragging) started();
			dragging = true; suppressClick = true;
			var next = insertionAt(event.y);
			event.preventDefault();
			if (next != insertion) { insertion = next; repaint(); }
		});
		root.on(UiEventKind.PointerUp, function(event) {
			if (event.button != 0 || source == null || pointer != event.pointerId) return;
			var from:String = source;
			var moved = dragging, target = dragging ? insertionAt(event.y) : -1;
			clear(); repaint();
			if (!moved) return;
			event.preventDefault();
			if (target >= 0) model.moveMode(from, target < order.length ? order[target] : null);
		});
		root.on(UiEventKind.PointerCancel, function(event) {
			if (pointer != event.pointerId) return;
			clear(); repaint();
		});
		root.on(UiEventKind.KeyDown, function(event) {
			if (source != null && event.key == UiKey.Escape) {
				clear(); suppressClick = true; event.preventDefault(); repaint();
				return;
			}
			if (menu == null || !UiKey.isContextMenuRequest(event.key, event.modifiers)) return;
			var focused = root.find(event.target);
			var key = focused == null ? null : focused.styleKey;
			var id = key != null && StringTools.startsWith(key, "activity:") ? key.substr(9) : null;
			menu(id != null && model.find(id) != null ? id : null, event);
			event.preventDefault(); event.stopPropagation();
		}, "capture");
		root.on(UiEventKind.Click, function(event) {
			if (suppressClick) { event.preventDefault(); event.stopImmediatePropagation(); }
		}, "capture");
	}
}
