package workspace.client;

import sys.FileSystem;
import sys.io.File;

/**
	Which manager the editor uses for each workspace folder, when not the one on the folder's default state: chosen in
	the Machine view and kept in `workspace-managers.conf`. Every client of a folder follows the choice, the
	Workbench's and the terminals', and reconnects when it changes.
**/
class WorkspaceManagerChoices {
	public static inline final VERSION = 1;
	static var shared:Null<WorkspaceManagerChoices>;

	/** The editor's choices, in its state folder (PRAGTICAL_PORTABLE when set). */
	public static function instance():WorkspaceManagerChoices {
		if (shared == null) shared = new WorkspaceManagerChoices(config.ConfigurationPaths.workspaceManagers());
		return shared;
	}

	public var revision(default, null):Int = 0;
	final path:Null<String>;
	final states:Map<String, String> = [];
	final seeds:Map<String, String> = [];

	/** `path` null keeps the choices in memory only. */
	public function new(path:Null<String>) {
		this.path = path;
		if (path == null || !FileSystem.exists(path)) return;
		try {
			var lines = StringTools.replace(File.getContent(path), "\r", "").split("\n");
			if (lines.shift() != "version=" + VERSION) return;
			for (line in lines) {
				var tab = line.indexOf("\t");
				if (tab > 0 && tab < line.length - 1) states.set(line.substr(0, tab), line.substr(tab + 1));
			}
		} catch (_:Dynamic) {}
	}

	/** The state folder chosen for `root`, or null for the folder's default state. */
	public function stateFor(root:String):Null<String> return states.get(root);

	/** Uses the manager on `stateDir` for `root` from now on; null returns to the default state. */
	public function choose(root:String, stateDir:Null<String>):Void {
		if (states.get(root) == stateDir) return;
		if (stateDir == null) states.remove(root) else states.set(root, stateDir);
		seeds.remove(root);
		revision++;
		save();
	}

	/**
		Uses a new manager on `stateDir` for `root`, starting from a copy of the catalog in `seedFrom` if `stateDir` has
		none yet. The copy is requested until a client of the folder connects there.
	**/
	public function chooseCopy(root:String, stateDir:String, seedFrom:String):Void {
		choose(root, stateDir);
		seeds.set(root, seedFrom);
	}

	/** The state to copy when a client starts the chosen manager for `root`, if one was asked for. */
	public function seedFor(root:String):Null<String> return seeds.get(root);

	/** A client reached the chosen manager; it no longer needs a copy. */
	public function connected(root:String):Void seeds.remove(root);

	function save():Void {
		if (path == null) return;
		try {
			var directory = haxe.io.Path.directory(path);
			if (directory.length > 0 && !FileSystem.exists(directory)) FileSystem.createDirectory(directory);
			var lines = ["version=" + VERSION];
			for (root => state in states) lines.push(root + "\t" + state);
			sys.io.AtomicFile.write(path, lines.join("\n") + "\n");
		} catch (_:Dynamic) {}
	}
}
