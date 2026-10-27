package ui;

import commandview.CommandView;
import commandview.CommandViewProvider;
import haxeon.ui.LayoutAlignmentY;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.Insets;
import haxeon.ui.TextWrap;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Key;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.TextStyleOverride;
import haxeon.ui.core.UiEventKind;
import haxeon.ui.core.UiKey;
import haxeon.ui.core.UiModifier;
import haxeon.ui.core.View;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.commands.SearchPicker;
import haxeon.ui.widgets.commands.SearchPickerModel;
import haxeon.ui.widgets.commands.ShortcutKeycaps;
import haxeon.ui.widgets.layout.Column;
import haxeon.ui.widgets.layout.Row;
import haxeon.ui.widgets.text.MiddleEllipsisText;
import haxeon.ui.widgets.text.Text;
import platform.Platform;

/** File/command presentation and model adapter for UIKit's searchable picker. */
class QuickPickView implements View {
	final model:CommandView;
	final provider:CommandViewProvider;
	final configureKeybinding:Null<String->Void>;
	final picker:SearchPicker;
	var atlas:SetiIconAtlas;
	public function new(model:CommandView, provider:CommandViewProvider, dismiss:Void->Void,
			changed:Void->Void, ?configureKeybinding:String->Void) {
		this.model = model; this.provider = provider; this.configureKeybinding = configureKeybinding;
		picker = new SearchPicker("command-view", new CommandViewPickerModel(model), buildRow, dismiss, changed);
		picker.width = 720;
		picker.placeholder = provider.prompt.length == 0 ? "Search files by name" : provider.prompt == "> " ? "Type a command" : provider.prompt;
		picker.prefix = provider.prompt == "> " ? ">" : "";
		picker.label = provider.prompt.length == 0 ? "Quick Open" : "Command Palette";
	}

	public function build(context:BuildContext):RenderNode {
		return context.withScope(new Key("quick-pick"), function() {
			var width = Math.max(1.0, Math.min(720.0, context.viewportWidth - 24.0));
			picker.rowHeight = provider.prompt.length == 0 && width < 520 ? 52 : 32;
			atlas = context.resourceState(context.id("cv-icons"), function() return new SetiIconAtlas(), function(value) value.dispose()).value;
			return picker.build(context);
		});
	}

	function buildRow(context:BuildContext, index:Int, selected:Bool, hovered:Bool, tooltipDismissRevision:Int):View {
		var tokens = context.theme.tokens;
		var width = Math.max(1.0, Math.min(720.0, context.viewportWidth - 24.0));
		var narrow = width < 520, files = provider.prompt.length == 0, commands = provider.prompt == "> ";
		var rowHeight = picker.rowHeight;
		var dark = context.environment.colorScheme == haxeon.ui.style.EnvironmentColorScheme.Dark;
		var entry = model.results[index];
		var foreground = !entry.enabled ? tokens.textSecondary : selected ? tokens.textOnAccent : tokens.textPrimary;
		var secondary = selected ? tokens.textOnAccent : tokens.textSecondary;
		var rowStyle = new LayoutStyle();
		rowStyle.width = LayoutAxis.grow();
		rowStyle.height = LayoutAxis.fixed(rowHeight);
		rowStyle.padding = new Insets(8.0, 0.0, 8.0, 0.0);
		rowStyle.childGap = 8.0;
		rowStyle.childAlignY = LayoutAlignmentY.Center;
		rowStyle.background = selected ? tokens.accent : hovered ? tokens.navigationHover : tokens.navigationBackground;
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
			if (!commands && detail.length > 0) {
				// Keep descriptions aligned regardless of each option's label length.
				var nameStyle = new LayoutStyle();
				nameStyle.width = LayoutAxis.fixed(Math.max(1.0, (width - 36.0) * 0.45));
				nameStyle.clipHorizontal = true;
				cells.push(new KeyedView("name", new Row("cv-option-name", [new KeyedView("label", labelView)], nameStyle)));
			} else cells.push(new KeyedView("name", labelView));
			if (!commands && detail.length > 0) cells.push(new KeyedView("detail", detailView));
			if (entry.trailing.length > 0) cells.push(new KeyedView("shortcut", new ShortcutKeycaps(entry.trailing, selected)));
			if (commands && configureKeybinding != null && (selected || hovered)) {
				var tooltip = new haxeon.ui.widgets.overlays.Tooltip("configure-keybinding-tooltip",
					new QuickPickGear(foreground, function() {
						var configure:String->Void = cast configureKeybinding; configure(entry.value);
					}), new Text("Configure Keybinding"), -150.0, -32.0);
				tooltip.requirePointerMovement = true;
				tooltip.dismissRevision = tooltipDismissRevision;
				cells.push(new KeyedView("configure", tooltip));
			}
		}
		return new Row("cv-row-" + index, cells, rowStyle);
	}
}

private class CommandViewPickerModel implements SearchPickerModel {
	final model:CommandView;
	public function new(model:CommandView) this.model = model;
	public function query():String return model.query;
	public function selectedIndex():Int return model.selected;
	public function count():Int return model.results.length;
	public function labelAt(index:Int):String {
		var entry = model.results[index];
		return entry.enabled ? entry.label : entry.label + ". " + entry.detail;
	}
	public function enabledAt(index:Int):Bool return model.results[index].enabled;
	public function setQuery(value:String):Void model.setQuery(value);
	public function activate(index:Int):Void model.activate(index);
	public function navigate(key:Int, modifiers:Int, pageSize:Int):Void {
		var legacy = switch key {
			case UiKey.Up, UiKey.PageUp: Platform.KEY_UP;
			case UiKey.Down, UiKey.PageDown: Platform.KEY_DOWN;
			case UiKey.Enter: Platform.KEY_ENTER;
			case UiKey.Tab: Platform.KEY_TAB;
			default: -1;
		};
		if (legacy < 0) return;
		var count = key == UiKey.PageUp || key == UiKey.PageDown ? pageSize : 1;
		for (_ in 0...count) model.keyPressed(legacy, (modifiers & UiModifier.Shift) != 0 ? Platform.MOD_SHIFT : 0);
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
