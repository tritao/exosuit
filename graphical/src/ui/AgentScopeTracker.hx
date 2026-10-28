package ui;

/**
	Follows the Workbench selection into the current scope (see AgentScope.resolve) and keeps it between frames. The
	directory is normalized through the file system once per new spelling, not on every frame.
**/
class AgentScopeTracker {
	final normalize:String->String;
	/** The last scope, its directory normalized; also the fallback when the selection has no group. */
	var current:Null<AgentScope>;
	/** The scope directory as the Workbench service spells it, and that same path normalized by `normalize`. */
	var serviceDirectory:String = "";
	var normalizedDirectory:String = "";

	/** `normalize` may throw for a folder that is gone; the service's spelling is kept then. */
	public function new(normalize:String->String) this.normalize = normalize;

	public function resolve(model:WorkbenchTreeModel, selectedKey:Null<String>):Null<AgentScope> {
		// `current` carries the normalized directory, which never compares with the service's; resolve against that.
		var previous = current == null ? null : current.withDirectory(serviceDirectory);
		var next = AgentScope.resolve(model, selectedKey, previous);
		if (next == null) {
			current = null;
			return null;
		}
		if (next.directory != serviceDirectory) {
			serviceDirectory = next.directory;
			normalizedDirectory = try normalize(next.directory) catch (_:Dynamic) next.directory;
		}
		var scoped = next.withDirectory(normalizedDirectory);
		if (!scoped.equals(current)) current = scoped;
		return current;
	}

	/** Forget the last scope, e.g. when the Workbench service detaches. */
	public function reset():Void {
		current = null; serviceDirectory = ""; normalizedDirectory = "";
	}
}
