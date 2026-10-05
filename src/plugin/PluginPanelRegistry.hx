package plugin;

class PluginPanelRegistry {
	final registered:Array<PluginPanel> = [];

	public var revision(default, null):Int = 0;
	public function changed():Void revision++;

	public function new() {}

	public function add(owner:String, id:String, title:String, text:String):PluginPanel {
		if (id.length == 0 || title.length == 0) throw "plugin panels require an id and title";
		if (find(owner, id) != null) throw 'plugin panel "$owner:$id" is already registered';
		var panel = new PluginPanel(owner, id, title, text);
		registered.push(panel);
		revision++;
		return panel;
	}

	public function find(owner:String, id:String):Null<PluginPanel> {
		for (panel in registered) if (panel.owner == owner && panel.id == id) return panel;
		return null;
	}

	public function remove(panel:PluginPanel):Void {
		if (registered.remove(panel)) revision++;
	}

	public function removeOwner(owner:String):Void {
		var index = registered.length;
		while (index > 0) {
			index--;
			if (registered[index].owner == owner) { registered.splice(index, 1); revision++; }
		}
	}

	public function panels():Array<PluginPanel>
		return registered.copy();
}
