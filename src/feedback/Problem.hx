package feedback;

class Problem {
	public final owner:String;
	public final id:String;
	public final scope:ProblemScope;
	public final location:Null<ProblemLocation>;
	public final message:String;
	public final severity:Int;
	public final source:String;
	public final code:String;
	public final actions:Array<ProblemAction>;
	public final details:Array<ProblemDetail>;
	/** Compatibility accessors for file diagnostics. Navigation uses location. */
	public var path(get, never):String;
	public var line(get, never):Int;
	public var column(get, never):Int;
	public var endColumn(get, never):Int;
	function get_path():String return location == null ? "" : location.path;
	function get_line():Int return location == null ? 0 : location.line;
	function get_column():Int return location == null ? 0 : location.column;
	function get_endColumn():Int return location == null ? 0 : location.endColumn;

	public function new(owner:String, id:String, path:Null<String>, line:Int, column:Int, endColumn:Int, message:String, severity:Int,
			?scope:ProblemScope, source:String = "", code:String = "", ?actions:Array<ProblemAction>, ?details:Array<ProblemDetail>) {
		this.owner = owner; this.id = id;
		this.location = path == null || path.length == 0 ? null : new ProblemLocation(path, line, column, endColumn);
		this.scope = scope == null ? (location == null ? Workspace : File(path)) : scope;
		this.message = message; this.severity = severity; this.source = source; this.code = code;
		this.actions = actions == null ? [] : actions.copy();
		this.details = details == null ? [] : details.copy();
	}
	public static function scoped(owner:String, id:String, scope:ProblemScope, message:String, severity:Int,
			source:String = "", ?actions:Array<ProblemAction>):Problem
		return new Problem(owner, id, null, 0, 0, 0, message, severity, scope, source, "", actions);
	public function same(other:Problem):Bool {
		if (key() != other.key() || scopeKey() != other.scopeKey() || path != other.path || line != other.line || column != other.column ||
			endColumn != other.endColumn || message != other.message || severity != other.severity || source != other.source || code != other.code ||
			actions.length != other.actions.length || details.length != other.details.length) return false;
		for (index in 0...actions.length) if (actions[index].label != other.actions[index].label || actions[index].command != other.actions[index].command) return false;
		for (index in 0...details.length) {
			var a = details[index], b = other.details[index];
			if (a.message != b.message) return false;
			var al = a.location, bl = b.location;
			if (al == null ? bl != null : bl == null || al.path != bl.path || al.line != bl.line || al.column != bl.column || al.endColumn != bl.endColumn) return false;
		}
		return true;
	}

	public function key():String return owner.length + ":" + owner + id;
	public function forAction(action:ProblemAction):Problem
		return scoped(owner, id, scope, message, severity, source, [action]);
	public function scopeKey():String return switch scope {
		case File(path): "file:" + path;
		case Project(root): "project:" + root;
		case Workspace: "workspace";
	};
	public function scopeLabel():String return switch scope {
		case File(path): path;
		case Project(root): "Project: " + root;
		case Workspace: "Workspace";
	};
}
