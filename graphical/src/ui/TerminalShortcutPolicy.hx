package ui;

/** Application commands whose current bindings take priority over terminal input.
 * Overrides add IDs or remove defaults with a leading minus; the last entry wins.
 * Domain IDs are accepted without the UI bridge's "exosuit." prefix.
 */
class TerminalShortcutPolicy {
	static final defaults:Array<String> = [
		"view.toggle-palette", "commands:open", "files:open",
		"file.new", "file.open", "file.open-folder",
		"view.terminal", "terminal:new", "terminal:browse",
		"terminal:move-to-editor", "terminal:move-to-panel",
		"preferences.open", "settings:open", "editor.toggle-tab-focus",
		"view.zoom-in", "view.zoom-out", "view.zoom-reset",
		"view.layout-bottom", "view.layout-right", "view.layout-menu",
		"root:switch-to-next-tab", "root:switch-to-previous-tab",
		"workbench:toggle-sidebar", "workspace:search", "sidebar:files", "sidebar:search",
		"navigation:go-back", "navigation:go-forward", "navigation:go-to-line",
		"layout:focus-left", "layout:focus-right", "layout:focus-up", "layout:focus-down",
		"layout:move-tab-left", "layout:move-tab-right", "layout:move-tab-up", "layout:move-tab-down",
		"layout:reorder-tab-left", "layout:reorder-tab-right"
	];

	public static function allows(id:String, ?overrides:Array<String>):Bool {
		var name = normalize(id);
		var allowed = defaults.indexOf(name) >= 0;
		if (overrides != null) for (entry in overrides) {
			var remove = StringTools.startsWith(entry, "-");
			if (normalize(remove ? entry.substring(1) : entry) == name) allowed = !remove;
		}
		return allowed;
	}

	static function normalize(id:String):String
		return StringTools.startsWith(id, "exosuit.") ? id.substring(8) : id;
}
