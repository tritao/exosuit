package workspace.provider;

import haxe.io.Path;
import haxeon.agent.AgentTool;
import haxeon.agent.JsonObject;
import haxeon.agent.ToolAccess;
import haxeon.agent.ToolContext;
import haxeon.agent.ToolResult;
import haxeon.agent.ToolSchema;
import sys.FileSystem;
import sys.io.AtomicFile;
import sys.io.File;

/** Resolves model-supplied paths against one workspace directory and refuses anything that leaves it. */
private class AgentKitSandbox {
	public final root:String;

	public function new(root:String)
		this.root = FileSystem.fullPath(root);

	/** Absolute path for `relative` when it exists inside the root, following symlinks; otherwise null. */
	public function existing(relative:String):Null<String> {
		try {
			var full = FileSystem.fullPath(Path.isAbsolute(relative) ? relative : Path.join([root, relative]));
			return contains(full) && FileSystem.exists(full) ? full : null;
		} catch (_:Dynamic)
			return null;
	}

	/** Path for a file to create: its parent directory must already exist inside the root. */
	public function creatable(relative:String):Null<String> {
		try {
			var joined = Path.isAbsolute(relative) ? relative : Path.join([root, relative]);
			var parent = FileSystem.fullPath(Path.directory(joined));
			var full = Path.join([parent, Path.withoutDirectory(joined)]);
			return contains(full) && FileSystem.isDirectory(parent) && Path.withoutDirectory(joined) != "" ? full : null;
		} catch (_:Dynamic)
			return null;
	}

	public function contains(path:String):Bool
		return workspace.runtime.WorkspaceDirectories.contains(root, path, Sys.systemName() == "Windows");

	public function relative(path:String):String
		return path.length <= root.length ? "." : path.substr(StringTools.endsWith(root, "/") || StringTools.endsWith(root, "\\") ? root.length : root.length + 1);
}

private class SandboxTool extends AgentTool {
	final sandbox:AgentKitSandbox;

	public function new(sandbox:AgentKitSandbox, name:String, description:String, schema:ToolSchema, access:ToolAccess) {
		super(name, description, schema, access);
		this.sandbox = sandbox;
	}

	function box():AgentKitSandbox
		return sandbox;

	function readText(path:String, limit:Int):Null<String> {
		var meta = FileSystem.metadata(path);
		if (meta == null || FileSystem.isDirectory(path) || meta.size > limit)
			return null;
		// HashLink strings cannot hold NUL, so binary detection must look at the bytes.
		var bytes = File.getBytes(path);
		for (index in 0...bytes.length)
			if (bytes.get(index) == 0)
				return null;
		return bytes.toString();
	}
}

private class ReadFileTool extends SandboxTool {
	static inline var MaxBytes = 2097152;
	static inline var MaxOutput = 65536;

	public function new(sandbox:AgentKitSandbox)
		super(sandbox, "read_file", "Read a text file from the workspace. Returns numbered lines; use offset and limit for large files.", new ToolSchema()
			.string("path", "File path relative to the workspace root")
			.integer("offset", "First line to read, starting at 1")
			.integer("limit", "Maximum number of lines to return"), ReadOnly);

	override function summarize(input:JsonObject):String
		return "Read " + input.string("path");

	override function execute(input:JsonObject, context:ToolContext, done:ToolResult->Void):Void {
		var path = box().existing(input.string("path"));
		if (path == null) {
			done(ToolResult.error("Path is outside the workspace or does not exist"));
			return;
		}
		var text = readText(path, MaxBytes);
		if (text == null) {
			done(ToolResult.error("Not a readable text file under 2 MiB"));
			return;
		}
		var lines = text.split("\n");
		var first = Std.int(Math.max(1, input.int("offset", 1)));
		var count = Std.int(Math.max(1, input.int("limit", 2000)));
		var out = new StringBuf();
		var written = 0;
		var index = first - 1;
		while (index < lines.length && index - (first - 1) < count) {
			var line = (index + 1) + "\t" + lines[index] + "\n";
			if (written + line.length > MaxOutput) {
				out.add("[truncated: continue with offset " + (index + 1) + "]\n");
				break;
			}
			out.add(line);
			written += line.length;
			index++;
		}
		done(ToolResult.ok(out.toString()));
	}
}

private class ListDirectoryTool extends SandboxTool {
	static inline var MaxEntries = 500;

	public function new(sandbox:AgentKitSandbox)
		super(sandbox, "list_directory", "List the entries of a workspace directory. Directories end with a slash.", new ToolSchema().string("path",
			"Directory relative to the workspace root; defaults to the root", false), ReadOnly);

	override function summarize(input:JsonObject):String
		return "List " + (input.string("path") == "" ? "." : input.string("path"));

	override function execute(input:JsonObject, context:ToolContext, done:ToolResult->Void):Void {
		var requested = input.string("path");
		var path = requested == "" ? box().root : box().existing(requested);
		if (path == null || !FileSystem.isDirectory(path)) {
			done(ToolResult.error("Not a directory inside the workspace"));
			return;
		}
		var entries = FileSystem.readDirectoryEntries(path);
		entries.sort(function(a, b) return a.isDirectory != b.isDirectory ? (a.isDirectory ? -1 : 1) : Reflect.compare(a.name, b.name));
		var lines = [for (entry in entries.slice(0, MaxEntries)) entry.name + (entry.isDirectory ? "/" : "")];
		if (entries.length > MaxEntries)
			lines.push("[" + (entries.length - MaxEntries) + " more entries not shown]");
		done(ToolResult.ok(lines.join("\n")));
	}
}

private class SearchTool extends SandboxTool {
	static inline var MaxMatches = 100;
	static inline var MaxFiles = 3000;
	static inline var MaxFileBytes = 1048576;
	static final skipped = [".git", "node_modules", "build", "out", ".hg", ".svn"];

	var visited = 0;

	public function new(sandbox:AgentKitSandbox)
		super(sandbox, "search_files", "Find lines containing a literal text in workspace files. Skips build output and VCS directories.", new ToolSchema()
			.string("query", "Literal text to search for")
			.string("path", "Directory relative to the workspace root; defaults to the root", false), ReadOnly);

	override function summarize(input:JsonObject):String
		return "Search for \"" + input.string("query") + "\"";

	override function execute(input:JsonObject, context:ToolContext, done:ToolResult->Void):Void {
		var query = input.string("query");
		var requested = input.string("path");
		var start = requested == "" ? box().root : box().existing(requested);
		if (query == "" || start == null || !FileSystem.isDirectory(start)) {
			done(ToolResult.error("A query and a directory inside the workspace are required"));
			return;
		}
		visited = 0;
		var matches:Array<String> = [];
		walk(start, query, matches);
		var note = matches.length >= MaxMatches ? "\n[stopped at " + MaxMatches + " matches]" : visited >= MaxFiles ? "\n[stopped after " + MaxFiles + " files]" : "";
		done(ToolResult.ok(matches.length == 0 ? "No matches" + note : matches.join("\n") + note));
	}

	function walk(directory:String, query:String, matches:Array<String>):Void {
		var entries = FileSystem.readDirectoryEntries(directory);
		entries.sort(function(a, b) return Reflect.compare(a.name, b.name));
		for (entry in entries) {
			if (matches.length >= MaxMatches || visited >= MaxFiles)
				return;
			var path = Path.join([directory, entry.name]);
			if (entry.isDirectory) {
				// A symlinked directory could point outside the root; re-check containment before descending.
				if (skipped.indexOf(entry.name) < 0 && box().contains(FileSystem.fullPath(path)))
					walk(path, query, matches);
				continue;
			}
			visited++;
			var text = readText(path, MaxFileBytes);
			if (text == null)
				continue;
			var lineNumber = 0;
			for (line in text.split("\n")) {
				lineNumber++;
				if (line.indexOf(query) >= 0) {
					matches.push(box().relative(path) + ":" + lineNumber + ": " + line.substr(0, 200));
					if (matches.length >= MaxMatches)
						return;
				}
			}
		}
	}
}

private class WriteFileTool extends SandboxTool {
	static inline var MaxBytes = 1048576;

	public function new(sandbox:AgentKitSandbox)
		super(sandbox, "write_file", "Create or overwrite a text file. The parent directory must already exist.", new ToolSchema()
			.string("path", "File path relative to the workspace root")
			.string("content", "Complete new file content"), Mutating);

	override function summarize(input:JsonObject):String
		return "Write " + input.string("path") + " (" + input.string("content").length + " characters)";

	override function execute(input:JsonObject, context:ToolContext, done:ToolResult->Void):Void {
		var path = box().creatable(input.string("path"));
		var content = input.string("content");
		if (path == null || content.length > MaxBytes) {
			done(ToolResult.error("Path must be inside the workspace with an existing parent directory, and content under 1 MiB"));
			return;
		}
		if (FileSystem.exists(path) && FileSystem.isDirectory(path)) {
			done(ToolResult.error("Path is a directory"));
			return;
		}
		AtomicFile.write(path, content);
		done(ToolResult.ok("Wrote " + box().relative(path)));
	}
}

private class EditFileTool extends SandboxTool {
	static inline var MaxBytes = 2097152;

	public function new(sandbox:AgentKitSandbox)
		super(sandbox, "edit_file", "Replace one exact occurrence of text in a file. Fails unless old_text appears exactly once.", new ToolSchema()
			.string("path", "File path relative to the workspace root")
			.string("old_text", "Exact text to replace; must be unique in the file")
			.string("new_text", "Replacement text"), Mutating);

	override function summarize(input:JsonObject):String
		return "Edit " + input.string("path");

	override function execute(input:JsonObject, context:ToolContext, done:ToolResult->Void):Void {
		var path = box().existing(input.string("path"));
		var oldText = input.string("old_text");
		if (path == null || oldText == "") {
			done(ToolResult.error("Path must exist inside the workspace and old_text must not be empty"));
			return;
		}
		var text = readText(path, MaxBytes);
		if (text == null) {
			done(ToolResult.error("Not an editable text file under 2 MiB"));
			return;
		}
		var first = text.indexOf(oldText);
		if (first < 0) {
			done(ToolResult.error("old_text was not found"));
			return;
		}
		if (text.indexOf(oldText, first + oldText.length) >= 0) {
			done(ToolResult.error("old_text appears more than once; include more surrounding context"));
			return;
		}
		AtomicFile.write(path, text.substr(0, first) + input.string("new_text") + text.substr(first + oldText.length));
		done(ToolResult.ok("Edited " + box().relative(path)));
	}
}

/** The file tools a Workbench agent session offers, confined to one workspace directory. */
class AgentKitTools {
	public static function forDirectory(directory:String):Array<AgentTool> {
		var sandbox = new AgentKitSandbox(directory);
		return [
			new ReadFileTool(sandbox),
			new ListDirectoryTool(sandbox),
			new SearchTool(sandbox),
			new WriteFileTool(sandbox),
			new EditFileTool(sandbox)
		];
	}
}
