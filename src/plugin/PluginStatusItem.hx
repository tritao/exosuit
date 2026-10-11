package plugin;

import haxeon.ui.icons.IconName;

class PluginStatusItem {
	public final owner:String;
	public final id:String;
	public var text:String;
	public var priority:Int;
	public var side:PluginStatusSide;
	public var icon:Null<IconName>;
	public var tooltip:String;
	public var command:String;

	public function new(owner:String, id:String, text:String, priority:Int,
			side:PluginStatusSide, icon:Null<IconName>, tooltip:String, command:String) {
		this.owner = owner;
		this.id = id;
		this.text = text == null ? "" : text;
		this.priority = priority;
		this.side = side;
		this.icon = icon;
		this.tooltip = tooltip == null ? "" : tooltip;
		this.command = command == null ? "" : command;
	}
}
