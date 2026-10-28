package suit;

import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitTypes;

/** Builds one native popup menu; item actions stay valid until the next menu is built. */
class SuitMenu implements SuitMenuModel.SuitMenuSink {
	final menu:OwnedMenuHandle;
	final actions:Map<Int, Void->Void>;
	final parents:Map<Int, OwnedMenuItemHandle> = [];
	var nextId:Int = 1;

	public function new(menu:OwnedMenuHandle, actions:Map<Int, Void->Void>) {
		this.menu = menu;
		this.actions = actions;
	}

	public function item(label:String, action:Null<Void->Void>, parent:Int):Void {
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
		add(options, parent);
	}

	public function submenu(label:String, parent:Int):Int {
		var options = new MenuItemOptions();
		options.set_kind(MenuItemKind.Submenu);
		options.set_label(label);
		var id = nextId++;
		parents.set(id, add(options, parent));
		return id;
	}

	public function check(label:String, checked:Bool, action:Void->Void, parent:Int):Void {
		var options = new MenuItemOptions();
		options.set_kind(MenuItemKind.Checkbox);
		options.set_label(label);
		if (checked)
			options.set_flags(MenuItemFlags.Checked);
		var id = nextId++;
		actions.set(id, action);
		options.set_command_id(haxe.Int64.ofInt(id));
		add(options, parent);
	}

	public function separator(parent:Int):Void {
		var options = new MenuItemOptions();
		options.set_kind(MenuItemKind.Separator);
		add(options, parent);
	}

	function add(options:MenuItemOptions, parent:Int):OwnedMenuItemHandle {
		var owner = parents.get(parent);
		return NativeKit.nk_menu_add_item_checked(menu.borrow(), owner == null ? MenuItemHandle.invalid() : owner.borrow(), options);
	}
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
	public function show(build:SuitMenuModel.SuitMenuSink->Void):Void {
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

	/** Builds the native menu without showing it; returns its command count. For `suit tray-check`. */
	public function build(build:SuitMenuModel.SuitMenuSink->Void):Int {
		actions.clear();
		var menu = NativeKit.nk_menu_create_checked(new MenuOptions());
		try build(new SuitMenu(menu, actions)) catch (error:Dynamic) {
			menu.close();
			throw error;
		}
		menu.close();
		var count = 0;
		for (_ in actions)
			count++;
		return count;
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
