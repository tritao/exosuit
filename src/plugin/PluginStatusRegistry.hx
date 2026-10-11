package plugin;

import haxeon.ui.icons.IconName;

class PluginStatusRegistry {
	final values:Array<PluginStatusItem> = [];

	public var revision(default, null):Int = 0;
	public function changed():Void revision++;

	public function new() {}

	public function add(owner:String, id:String, text:String, priority:Int = 0,
			side:PluginStatusSide = Right, ?icon:IconName, tooltip:String = "", command:String = ""):PluginStatusItem {
		if (owner == null || owner.length == 0 || id == null || id.length == 0) throw "status item owner and id cannot be empty";
		if (side == null) throw "status item side is required";
		if (find(owner, id) != null) throw 'status item "$owner:$id" is already registered';
		var value = new PluginStatusItem(owner, id, text, priority, side, icon, tooltip, command);
		values.push(value);
		revision++;
		return value;
	}

	public function update(value:PluginStatusItem, text:String, priority:Int,
			side:PluginStatusSide, ?icon:IconName, tooltip:String = "", ?command:String):Bool {
		if (value == null || !values.contains(value)) return false;
		if (side == null) return false;
		var nextText = text == null ? "" : text;
		var nextTooltip = tooltip == null ? "" : tooltip;
		var nextCommand = command == null ? value.command : command;
		if (value.text == nextText && value.priority == priority && value.side == side && value.icon == icon &&
			value.tooltip == nextTooltip && value.command == nextCommand) return true;
		value.text = nextText;
		value.priority = priority;
		value.side = side;
		value.icon = icon;
		value.tooltip = nextTooltip;
		value.command = nextCommand;
		revision++;
		return true;
	}

	public function find(owner:String, id:String):Null<PluginStatusItem> {
		for (value in values) if (value.owner == owner && value.id == id) return value;
		return null;
	}

	public function items():Array<PluginStatusItem> {
		var result = values.copy();
		result.sort(function(a, b) {
			var order = b.priority - a.priority;
			return order == 0 ? Reflect.compare(a.owner + ":" + a.id, b.owner + ":" + b.id) : order;
		});
		return result;
	}

	public function remove(value:PluginStatusItem):Bool {
		if (!values.remove(value)) return false;
		revision++;
		return true;
	}
	public function removeOwner(owner:String):Void {
		var index = values.length;
		while (index > 0) {
			index--;
			if (values[index].owner == owner) { values.splice(index, 1); revision++; }
		}
	}
}
