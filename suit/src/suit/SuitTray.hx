package suit;

import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitTypes;

/** Builds one popup menu; item actions stay valid until the next menu is built. */
class SuitMenu {
	final menu:OwnedMenuHandle;
	final actions:Map<Int, Void->Void>;
	var nextId:Int = 1;

	public function new(menu:OwnedMenuHandle, actions:Map<Int, Void->Void>) {
		this.menu = menu;
		this.actions = actions;
	}

	public function item(label:String, ?action:Void->Void, ?parent:OwnedMenuItemHandle):OwnedMenuItemHandle {
		var options = new MenuItemOptions();
		options.set_kind(MenuItemKind.Command);
		options.set_label(label);
		if (action == null)
			options.set_flags(MenuItemFlags.Disabled);
		else {
			var id = nextId++;
			actions.set(id, action);
			options.set_command_id(haxe.Int64.ofInt(id));
		}
		return add(options, parent);
	}

	public function submenu(label:String, ?parent:OwnedMenuItemHandle):OwnedMenuItemHandle {
		var options = new MenuItemOptions();
		options.set_kind(MenuItemKind.Submenu);
		options.set_label(label);
		return add(options, parent);
	}

	public function separator(?parent:OwnedMenuItemHandle):Void {
		var options = new MenuItemOptions();
		options.set_kind(MenuItemKind.Separator);
		add(options, parent);
	}

	function add(options:MenuItemOptions, parent:Null<OwnedMenuItemHandle>):OwnedMenuItemHandle
		return NativeKit.nk_menu_add_item_checked(menu.borrow(), parent == null ? MenuItemHandle.invalid() : parent.borrow(), options);
}

/**
	The Windows notification-area icon. A click asks for the menu; the daemon builds it from a fresh
	inventory each time, so it never shows stale processes.
**/
class SuitTray {
	final tray:OwnedTrayHandle;
	final actions:Map<Int, Void->Void> = [];
	var tooltip:String;

	public function new(tooltip:String, icon:Null<String>) {
		this.tooltip = tooltip;
		var options = new TrayOptions();
		options.set_tooltip(tooltip);
		if (icon != null)
			options.set_icon(icon);
		tray = NativeKit.nk_tray_create_checked(options);
	}

	public function owns(source:Int):Bool
		return source == tray.rawValue();

	public function setTooltip(text:String):Void {
		if (text == tooltip)
			return;
		tooltip = text;
		NativeKit.nk_tray_set_tooltip(tray.borrow(), text);
	}

	/** Shows a menu built by `build`; returns once it closes. The choice arrives later as an event. */
	public function show(build:SuitMenu->Void):Void {
		actions.clear();
		var menu = NativeKit.nk_menu_create_checked(new MenuOptions());
		try {
			build(new SuitMenu(menu, actions));
			NativeKit.nk_tray_show_menu(tray.borrow(), menu.borrow());
		} catch (error:Dynamic) {
			menu.close();
			throw error;
		}
		menu.close();
	}

	/** Runs the action for a chosen command id. */
	public function activate(commandId:Int):Bool {
		var action = actions.get(commandId);
		if (action == null)
			return false;
		action();
		return true;
	}

	public function dispose():Void
		tray.close();
}
