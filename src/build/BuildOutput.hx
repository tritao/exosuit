package build;

class BuildOutput {
	public static inline final MAX_BYTES = 1024 * 1024;
	public static inline final MAX_LINES = 10000;
	public final lines:Array<BuildOutputLine> = [];
	public var byteCount(default, null):Int = 0;
	var pending:String = "";
	public var cwd(default, null):String = "";

	public function new() {}

	public function reset(cwd:String):Void {
		lines.resize(0);
		byteCount = 0;
		pending = "";
		this.cwd = cwd;
	}

	public function append(chunk:String):Void {
		if (chunk.length == 0) return;
		pending += chunk;
		var newline = pending.indexOf("\n");
		while (newline >= 0) {
			appendLine(StringTools.endsWith(pending.substring(0, newline), "\r") ? pending.substring(0, newline - 1) : pending.substring(0, newline));
			pending = pending.substring(newline + 1);
			newline = pending.indexOf("\n");
		}
		trimPending();
	}

	public function finish():Void {
		if (pending.length > 0) appendLine(pending);
		pending = "";
	}

	function appendLine(text:String):Void {
		if (text.length + 1 > MAX_BYTES) text = text.substring(text.length - MAX_BYTES + 1);
		var line = new BuildOutputLine(text, parseDiagnostic(text));
		lines.push(line);
		byteCount += text.length + 1;
		while (lines.length > MAX_LINES || byteCount > MAX_BYTES && lines.length > 1) {
			var removed = lines.shift();
			if (removed != null) byteCount -= removed.text.length + 1;
		}
	}

	function trimPending():Void {
		if (pending.length <= MAX_BYTES) return;
		pending = pending.substring(pending.length - MAX_BYTES);
	}

	function parseDiagnostic(text:String):Null<BuildDiagnostic> {
		var first = text.indexOf(":"), second = first < 0 ? -1 : text.indexOf(":", first + 1), third = second < 0 ? -1 : text.indexOf(":", second + 1);
		if (first <= 0 || second <= first + 1) return null;
		var line = Std.parseInt(text.substring(first + 1, second));
		if (line <= 0) return null;
		var column = 1;
		if (third > second + 1) {
			var parsed = Std.parseInt(text.substring(second + 1, third));
			if (parsed > 0) column = parsed;
		}
		var path = text.substring(0, first);
		if (!StringTools.startsWith(path, "/") && cwd.length > 0) path = cwd + "/" + path;
		return new BuildDiagnostic(path, line - 1, column - 1);
	}
}
