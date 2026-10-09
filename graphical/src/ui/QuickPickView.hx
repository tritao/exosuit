package ui;

import commandview.CommandView;
import commandview.CommandViewProvider;
import haxeon.ui.Insets;
import haxeon.ui.LayoutAlignmentY;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.TextStyle;
import haxeon.ui.TextWrap;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Key;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.TextStyleOverride;
import haxeon.ui.core.UiEvent;
import haxeon.ui.core.UiEventKind;
import haxeon.ui.core.UiKey;
import haxeon.ui.core.UiModifier;
import haxeon.ui.core.View;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.collections.VirtualList;
import haxeon.ui.widgets.layout.Column;
import haxeon.ui.widgets.layout.Row;
import haxeon.ui.widgets.overlays.Popup;
import haxeon.ui.widgets.scroll.ScrollController;
import haxeon.ui.widgets.text.MiddleEllipsisText;
import haxeon.ui.widgets.text.Text;
import haxeon.ui.widgets.text.TextField;
import platform.Platform;

/** Shared file/command picker with an editable input and non-focusable result rows. */
class QuickPickView implements View {
	final model:CommandView;
	final provider:CommandViewProvider;
	final dismiss:Void->Void;
	final changed:Void->Void;
	final configureKeybinding:Null<String->Void>;
	final scroll:ScrollController = new ScrollController();
	var focusPending:Bool = true;
	var previousQuery:String = "";
	var previousSelection:Int = -1;
	var previousRowHeight:Float = 0.0;
	var previousListHeight:Float = 0.0;
	var hovered:Int = -1;
	var tooltipDismissRevision:Int = 0;

	public function new(model:CommandView, provider:CommandViewProvider, dismiss:Void->Void, changed:Void->Void, ?configureKeybinding:String->Void) {
		this.model = model;
		this.provider = provider;
		this.dismiss = dismiss;
		this.changed = changed;
		this.configureKeybinding = configureKeybinding;
	}

	public function build(context:BuildContext):RenderNode {
		return context.withScope(new Key("quick-pick"), function() {
			var tokens = context.theme.tokens;
			var width = Math.max(1.0, Math.min(720.0, context.viewportWidth - 24.0));
			var narrow = width < 520.0;
			var files = provider.prompt.length == 0;
			var commands = provider.prompt == "> ";
			var rowHeight = files && narrow ? 52.0 : 32.0;
			var listHeight = Math.min(Math.max(rowHeight, model.results.length * rowHeight),
				Math.max(rowHeight, Math.min(360.0, context.viewportHeight - 80.0)));
			if (previousSelection != model.selected || previousQuery != model.query) tooltipDismissRevision++;
			var geometryChanged = previousRowHeight != rowHeight || previousListHeight != listHeight;
			if (previousQuery != model.query) { scroll.jumpTo(0, 0); hovered = -1; }
			if (previousSelection != model.selected || previousQuery != model.query
				|| geometryChanged) {
				var top = model.selected * rowHeight;
				if (top < scroll.offsetY) scroll.jumpTo(0, top);
				else if (top + rowHeight > scroll.offsetY + listHeight) scroll.jumpTo(0, top + rowHeight - listHeight);
			}
			previousQuery = model.query;
			previousSelection = model.selected;
			previousRowHeight = rowHeight;
			previousListHeight = listHeight;
			var inputStyle = new LayoutStyle();
			inputStyle.width = LayoutAxis.grow();
			inputStyle.height = LayoutAxis.fixed(34.0);
			inputStyle.padding = new Insets(8.0, 4.0, 8.0, 4.0);
			inputStyle.background = tokens.selectionField;
			var input = new TextField("cv-input", model.query, function(value) model.setQuery(value),
				inputStyle, provider.prompt.length == 0 ? "Search files by name" : "Search commands", new TextStyle(15.0), tokens.textPrimary);
			input.placeholder = provider.prompt.length == 0 ? "Search files by name" : provider.prompt == "> " ? "Type a command" : provider.prompt;
			input.onSubmit = function(_) { model.keyPressed(Platform.KEY_ENTER, 0); changed(); };
			var focusedInput = new QuickPickInput(input, function(ctx, node) {
				if (focusPending) { ctx.requestFocusAfterLayout(node.id); focusPending = false; }
			});
			var inputChildren:Array<KeyedView> = [];
			if (provider.prompt == "> ") inputChildren.push(new KeyedView("prefix", new Text(">", null, tokens.textSecondary, TextStyleOverride.text(15.0))));
			var inputRowStyle = new LayoutStyle();
			inputRowStyle.width = LayoutAxis.grow();
			inputRowStyle.childAlignY = LayoutAlignmentY.Center;
			inputRowStyle.childGap = 6.0;
			inputChildren.push(new KeyedView("field", focusedInput));
			var rows:Array<KeyedView> = [new KeyedView("input", new Row("cv-input-row", inputChildren, inputRowStyle))];
			var atlas = context.resourceState(context.id("cv-icons"), function() return new SetiIconAtlas(), function(value) value.dispose()).value;
			var dark = context.environment.colorScheme == haxeon.ui.style.EnvironmentColorScheme.Dark;
			var listStyle = new LayoutStyle();
			listStyle.width = LayoutAxis.grow();
			listStyle.height = LayoutAxis.fixed(listHeight);
			if (model.results.length == 0) {
				listStyle.padding = new Insets(10.0, 6.0, 10.0, 6.0);
				rows.push(new KeyedView("empty", new Text("No matching results", listStyle, tokens.textSecondary, TextStyleOverride.text(14.0))));
			} else {
				var list = new VirtualList("cv-scroll", model.results.length, rowHeight, function(index) {
					var entry = model.results[index];
					var selected = index == model.selected;
					var foreground = selected ? tokens.textOnAccent : tokens.textPrimary;
					var secondary = selected ? tokens.textOnAccent : tokens.textSecondary;
					var rowStyle = new LayoutStyle();
					rowStyle.width = LayoutAxis.grow();
					rowStyle.height = LayoutAxis.fixed(rowHeight);
					rowStyle.padding = new Insets(8.0, 0.0, 8.0, 0.0);
					rowStyle.childGap = 8.0;
					rowStyle.childAlignY = LayoutAlignmentY.Center;
					rowStyle.background = selected ? tokens.accent : index == hovered ? tokens.navigationHover : tokens.navigationBackground;
					var label = entry.label, detail = entry.detail;
					var cells:Array<KeyedView> = [];
					if (provider.prompt.length == 0) {
						var slash = label.lastIndexOf("/");
						if (slash >= 0) { detail += (detail.length > 0 ? " · " : "") + label.substring(0, slash); label = label.substring(slash + 1); }
						cells.push(new KeyedView("icon", new SetiFileIcon(atlas, label, dark, true)));
					}
					var labelView:View = new MiddleEllipsisText("cv-label", label, false,
						new TextStyleOverride(null, 15.0, null, TextWrap.None, null, null, null, foreground));
					var detailView:View = new MiddleEllipsisText("cv-path", detail, true,
						new TextStyleOverride(null, 13.0, null, TextWrap.None, null, null, null, secondary));
					var textStyle = new LayoutStyle(); textStyle.width = LayoutAxis.grow(); textStyle.clipHorizontal = true;
					if (files && narrow) {
						cells.push(new KeyedView("text", new Column("cv-file-text", [new KeyedView("name", labelView), new KeyedView("path", detailView)], textStyle)));
					} else if (files) {
						// Fixed filename allocation gives every breadcrumb the same starting x.
						var nameStyle = new LayoutStyle(); nameStyle.width = LayoutAxis.fixed(Math.max(1.0, (width - 60.0) * 0.45)); nameStyle.clipHorizontal = true;
						cells.push(new KeyedView("name", new Row("cv-name-column", [new KeyedView("name", labelView)], nameStyle)));
						cells.push(new KeyedView("path", detailView));
					} else {
						cells.push(new KeyedView("name", labelView));
						if (!commands && detail.length > 0) cells.push(new KeyedView("detail", detailView));
						if (entry.trailing.length > 0) cells.push(new KeyedView("shortcut", new ShortcutKeycaps(entry.trailing, selected)));
						if (commands && configureKeybinding != null && (selected || index == hovered)) {
							var tooltip = new haxeon.ui.widgets.overlays.Tooltip("configure-keybinding-tooltip",
								new QuickPickGear(foreground, function() {
									var configure:String->Void = cast configureKeybinding; configure(entry.value);
								}), new Text("Configure Keybinding"), -150.0, -32.0);
							tooltip.requirePointerMovement = true;
							tooltip.dismissRevision = tooltipDismissRevision;
							cells.push(new KeyedView("configure", tooltip));
						}
					}
					return new QuickPickRow(new Row("cv-result", cells, rowStyle), label, selected,
						function() { model.activate(index); changed(); },
						function(value) { hovered = value ? index : -1; changed(); });
				}, listStyle, null, scroll, listHeight);
				rows.push(new KeyedView("list", list));
			}
			var contentStyle = new LayoutStyle();
			contentStyle.width = LayoutAxis.fixed(width - 12.0);
			contentStyle.childGap = 6.0;
			var panelStyle = new LayoutStyle(); panelStyle.width = LayoutAxis.fixed(width); panelStyle.padding = new Insets(6.0, 6.0, 6.0, 6.0);
			var popup = new Popup("command-view", new Column("cv-content", rows, contentStyle),
				Math.max(0.0, (context.viewportWidth - width) / 2.0), 10.0, panelStyle, dismiss);
			popup.dimBackdrop = false;
			popup.menuSurface = true;
			popup.label = provider.prompt.length == 0 ? "Quick Open" : "Command Palette";
			var root = popup.build(context);
			root.on(UiEventKind.Scroll, function(_) {
				tooltipDismissRevision++;
				changed();
			}, "capture");
			// A resize can change the content extent before ScrollView resolves its
			// new metrics. Recheck once on the next frame, after those metrics settle.
			var recheckAfterLayout = geometryChanged;
			root.onResolved(function(_) {
				if (!recheckAfterLayout) return;
				recheckAfterLayout = false;
				previousSelection = -1;
				changed();
			});
			var navigate = function(event:UiEvent) {
				var key = switch event.key {
					case UiKey.Up: Platform.KEY_UP;
					case UiKey.Down: Platform.KEY_DOWN;
					case UiKey.Enter: Platform.KEY_ENTER;
					case UiKey.Tab: Platform.KEY_TAB;
					default: -1;
				};
				if (event.key == UiKey.PageUp || event.key == UiKey.PageDown) {
					for (_ in 0...Std.int(Math.max(1, listHeight / rowHeight))) model.keyPressed(event.key == UiKey.PageUp ? Platform.KEY_UP : Platform.KEY_DOWN, 0);
				} else if (key >= 0) model.keyPressed(key, (event.modifiers & UiModifier.Shift) != 0 ? Platform.MOD_SHIFT : 0);
				else return;
				changed(); event.preventDefault(); event.stopPropagation();
			};
			root.on(UiEventKind.KeyDown, navigate, "capture");
			root.on(UiEventKind.KeyRepeat, navigate, "capture");
			return root;
		});
	}
}

private class QuickPickInput implements View {
	final input:TextField;
	final resolved:(BuildContext, RenderNode)->Void;
	public function new(input:TextField, resolved:(BuildContext, RenderNode)->Void) { this.input = input; this.resolved = resolved; }
	public function build(context:BuildContext):RenderNode {
		var node = input.build(context); resolved(context, node); return node;
	}
}

private class QuickPickRow implements View {
	final child:View;
	final label:String;
	final selected:Bool;
	final activate:Void->Void;
	final hover:Bool->Void;
	public function new(child:View, label:String, selected:Bool, activate:Void->Void, hover:Bool->Void) {
		this.child = child; this.label = label; this.selected = selected; this.activate = activate; this.hover = hover;
	}
	public function build(context:BuildContext):RenderNode {
		var node = child.build(context);
		node.semantics = new haxeon.ui.semantics.Semantics(haxeon.ui.semantics.AccessibilityRole.Button, label);
		node.semantics.states = selected ? haxeon.ui.semantics.AccessibilityState.Selected : 0;
		node.semantics.actions = haxeon.ui.semantics.AccessibilityAction.Activate;
		node.on(UiEventKind.Click, function(event) { activate(); event.stopPropagation(); });
		node.on(UiEventKind.Activate, function(event) { activate(); event.stopPropagation(); });
		node.on(UiEventKind.HoverEnter, function(_) hover(true));
		node.on(UiEventKind.HoverLeave, function(_) hover(false));
		return node;
	}
}

/** Centered action shown only on the selected or hovered command. */
private class QuickPickGear implements View {
	final color:haxeon.ui.Color;
	final configure:Void->Void;
	public function new(color:haxeon.ui.Color, configure:Void->Void) {
		this.color = color; this.configure = configure;
	}
	public function build(context:BuildContext):RenderNode {
		var style = new LayoutStyle(); style.width = LayoutAxis.fixed(24); style.height = LayoutAxis.fixed(24);
		style.childDistribution = haxeon.ui.LayoutDistribution.Center;
		style.childAlignY = LayoutAlignmentY.Center;
		var icon:View = new haxeon.ui.widgets.Icon("configure-keybinding", haxeon.ui.icons.IconName.Settings, 16, color);
		var node = new Row("cv-configure", [new KeyedView("icon", icon)], style).build(context);
		node.semantics = new haxeon.ui.semantics.Semantics(haxeon.ui.semantics.AccessibilityRole.Button, "Configure Keybinding");
		node.semantics.actions = haxeon.ui.semantics.AccessibilityAction.Activate;
		node.on(UiEventKind.Click, function(event) { event.stopPropagation(); configure(); });
		node.on(UiEventKind.Activate, function(event) { event.stopPropagation(); configure(); });
		return node;
	}
}
