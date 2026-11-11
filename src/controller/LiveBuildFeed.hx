package controller;

import build.BuildDiagnostic;
import build.BuildOutput;
import core.WorkbenchHost;
import feedback.NotificationAction;
import feedback.NotificationKind;
import feedback.Problem;
import feedback.ProblemAction;
import feedback.ProblemScope;
import sys.FileSystem;
import sys.io.File;

/** One line of the watch's events file (haxeon `tools.WatchEvents`). Fields that do not apply are null or empty. */
class LiveWatchEvent {
	public final kind:String;
	public final time:Float;
	public final build:Null<Int>;
	public final revision:Null<Int>;
	public final line:String;
	public final message:String;
	public final changedFiles:Array<String>;
	public final reloadReasons:Array<String>;

	public function new(kind:String, time:Float, build:Null<Int>, revision:Null<Int>, line:String, message:String, changedFiles:Array<String>,
			reloadReasons:Array<String>) {
		this.kind = kind;
		this.time = time;
		this.build = build;
		this.revision = revision;
		this.line = line;
		this.message = message;
		this.changedFiles = changedFiles;
		this.reloadReasons = reloadReasons;
	}

	/** Null for a line that is not an event (a half-written one is never handed over: only whole lines are read). */
	public static function parse(text:String):Null<LiveWatchEvent> {
		var value:Dynamic = null;
		try value = haxe.Json.parse(text) catch (_:Dynamic) return null;
		if (value == null || !Std.isOfType(value.kind, String)) return null;
		var kind:String = value.kind;
		// JSON gives an Int for a small number and a Float past Int's range (epoch milliseconds).
		var time = Std.isOfType(value.time, Int) ? ((value.time : Int) : Float) : Std.isOfType(value.time, Float) ? (value.time : Float) : 0.0;
		return new LiveWatchEvent(kind, time,
			Std.isOfType(value.build, Int) ? (value.build : Int) : null, Std.isOfType(value.revision, Int) ? (value.revision : Int) : null,
			value.line == null ? "" : Std.string(value.line), value.message == null ? "" : Std.string(value.message),
			strings(value.changedFiles), strings(value.reloadReasons));
	}

	static function strings(value:Dynamic):Array<String> {
		if (value == null) return [];
		var items:Array<Dynamic> = value;
		return [for (item in items) Std.string(item)];
	}
}

/**
	Live mode (`scripts/run.py --live`): the watcher that rebuilds and patches this app appends what it does to the file
	named by HAXEON_WATCH_EVENTS. This feeds it into what the editor already has: the Build Output panel's "Live build"
	(the compiler's lines, `path:line:` ones clickable), Problems under the "live" owner (cleared by the next successful
	build), and a notification when a build fails or the app refuses a patch, with a quiet one when a later build
	succeeds. Without the variable there is no feed.

	The file only grows (a new watch empties it, a long one moves it aside), so a size check on the existing update pass
	finds new events; it is read whole, at most every `POLL_SECONDS`, only when its size changed.
**/
class LiveBuildFeed {
	public static inline final ENVIRONMENT = "HAXEON_WATCH_EVENTS";
	public static inline final PROBLEM_OWNER = "live";
	public static inline final SHOW_OUTPUT = "build:show-live-output";
	public static inline final TITLE = "Live build";
	static inline final POLL_SECONDS = 0.25;

	public final path:String;
	public final output:BuildOutput = new BuildOutput();
	/** The directory the compiler's relative paths are relative to: the project the watcher builds, where the app runs. */
	public final projectRoot:String;

	/** "", or the last result: "building", "ok", "failed", "patch-rejected". */
	public var state(default, null):String = "";
	public var revision(default, null):Null<Int> = null;
	/** Events applied so far; a change means Build Output, Problems or notifications may show something new. */
	public var applied(default, null) = 0;

	final root:WorkbenchHost;
	/** Events from before this feed started (a reloaded module reads the file again) are shown but not announced. */
	final startedAt:Float;
	var offset = 0;
	var size = -1;
	var nextPoll = 0.0;
	var failedLast = false;
	var sourceRoots:Null<Array<String>> = null;

	public function new(root:WorkbenchHost, path:String, projectRoot:String, ?startedAt:Float) {
		this.root = root;
		this.path = path;
		var normalized = StringTools.replace(projectRoot, "\\", "/");
		while (normalized.length > 1 && StringTools.endsWith(normalized, "/")) normalized = normalized.substring(0, normalized.length - 1);
		this.projectRoot = normalized;
		this.startedAt = startedAt == null ? Sys.time() * 1000.0 : startedAt;
		output.reset(this.projectRoot);
	}

	/** The feed for this process's watch, or null outside one. */
	public static function fromEnvironment(root:WorkbenchHost):Null<LiveBuildFeed> {
		var path = Sys.getEnv(ENVIRONMENT);
		return path == null || path.length == 0 ? null : new LiveBuildFeed(root, path, Sys.getCwd());
	}

	public function showOutput():Void
		root.showBuildOutput(TITLE, output);

	/** Reads new events when the file grew; true when any arrived. */
	public function update(now:Float):Bool {
		if (now < nextPoll) return false;
		nextPoll = now + POLL_SECONDS;
		var metadata = FileSystem.metadata(path);
		if (metadata == null || metadata.size == size) return false;
		// Smaller than what was read: a new watch emptied it, or a long one moved it aside.
		if (metadata.size < offset) offset = 0;
		var bytes:Null<haxe.io.Bytes> = null;
		try bytes = File.getBytes(path) catch (_:Dynamic) {}
		if (bytes == null) return false;
		var end = bytes.length;
		while (end > offset && bytes.get(end - 1) != "\n".code) end--;
		size = metadata.size;
		if (end <= offset) return false;
		var text = bytes.getString(offset, end - offset);
		offset = end;
		var any = false;
		for (line in text.split("\n")) {
			var event = LiveWatchEvent.parse(line);
			if (event == null) continue;
			apply(event);
			any = true;
		}
		return any;
	}

	public function apply(event:LiveWatchEvent):Void {
		var announce = event.time >= startedAt;
		applied++;
		switch event.kind {
			case "rebuild-started":
				state = "building";
				output.reset(projectRoot);
				output.append('Live rebuild ${event.build == null ? "" : Std.string(event.build)}'
					+ (event.changedFiles.length == 0 ? "" : ": " + event.changedFiles.join(", ")) + "\n");
			case "output-line":
				output.append(resolveLine(event.line) + "\n");
			case "build-failed":
				output.finish();
				state = "failed";
				failedLast = true;
				var problems = buildProblems();
				if (problems.length == 0)
					problems.push(Problem.scoped(PROBLEM_OWNER, "failed", ProblemScope.Workspace, "Live build failed; see Build Output", 1, TITLE,
						[new ProblemAction("Show live build output", SHOW_OUTPUT)]));
				root.getProblems().replaceOwner(PROBLEM_OWNER, problems);
				output.append("Live build failed; the app keeps running its last revision\n");
				if (announce) notifyFailure("Live build failed: " + problems[0].message);
			case "build-ok":
				output.finish();
				state = "ok";
				if (event.revision != null) revision = event.revision;
				root.getProblems().removeOwner(PROBLEM_OWNER);
				output.append("Live build succeeded" + (event.revision == null ? "" : ", revision " + event.revision) + "\n");
				if (failedLast && announce)
					root.getNotifications().publish("Live build succeeded" + (event.revision == null ? "" : " (revision " + event.revision + ")"),
						NotificationKind.Information, PROBLEM_OWNER);
				failedLast = false;
			case "patch-published":
				output.append("Published revision " + event.revision
					+ (event.reloadReasons.length == 0 ? "" : "; needs a reload: " + event.reloadReasons.join(", ")) + "\n");
			case "patch-applied":
				state = "ok";
				if (event.revision != null) revision = event.revision;
				output.append(event.message.length > 0 ? event.message + "\n" : "Patched revision " + event.revision + "\n");
			case "patch-rejected":
				state = "patch-rejected";
				failedLast = true;
				var message = event.message.length > 0 ? event.message : "The running app refused revision " + event.revision;
				output.append(message + "\n");
				root.getProblems().replaceOwner(PROBLEM_OWNER, [Problem.scoped(PROBLEM_OWNER, "rejected", ProblemScope.Workspace, message, 1, TITLE,
					[new ProblemAction("Show live build output", SHOW_OUTPUT)])]);
				if (announce) notifyFailure("Live patch rejected: " + message);
			case "reload":
				output.append((event.message.length > 0 ? event.message : "Reloading") + "\n");
			default:
		}
	}

	function notifyFailure(message:String):Void {
		root.getNotifications().publish(message, NotificationKind.Error, PROBLEM_OWNER, [new NotificationAction("Show output", showOutput)]);
	}

	/** Problems from the build's output: `path:line:column:` diagnostics, and compiler failures that name a class and member. */
	function buildProblems():Array<Problem> {
		var problems:Array<Problem> = [], seen:Map<String, Bool> = [];
		for (line in output.lines) {
			var diagnostic = line.diagnostic;
			if (diagnostic == null) diagnostic = symbolDiagnostic(line.text);
			if (diagnostic == null) continue;
			var identity = diagnostic.path + ":" + diagnostic.line + ":" + diagnostic.column + ":" + line.text;
			if (seen.exists(identity)) continue;
			seen.set(identity, true);
			problems.push(new Problem(PROBLEM_OWNER, identity, diagnostic.path, diagnostic.line, diagnostic.column, diagnostic.column + 1,
				line.text, 1, null, TITLE));
		}
		return problems;
	}

	/**
		The compiler names a file relative to the source root it found it in ("ui/EditorPane.hx:12:5: ..."), which Build
		Output would take as relative to the project: such a line gets the file's full path, when a source root has it.
	**/
	public function resolveLine(text:String):String {
		var colon = text.indexOf(".hx:");
		if (colon <= 0 || StringTools.startsWith(text, "/") || (text.length > 1 && text.charAt(1) == ":")) return text;
		var file = text.substring(0, colon + 3);
		if (file.indexOf(" ") >= 0 || file.indexOf("[") >= 0) return text;
		if (FileSystem.exists(projectRoot + "/" + file)) return text;
		for (directory in roots()) {
			var candidate = directory + "/" + file;
			if (FileSystem.exists(candidate)) return candidate + text.substring(colon + 3);
		}
		return text;
	}

	/**
		A compiler failure with no `path:line:` prefix that names the code it failed on, as `pack.Class.member`
		("HashLink lowering failed for $lambda:ui.EditorPane.build:build#onResolved(0)…"): the class's file under the
		project's source roots, at the member's declaration when the file declares it, else its first line.
	**/
	public function symbolDiagnostic(text:String):Null<BuildDiagnostic> {
		var lower = text.toLowerCase();
		if (lower.indexOf("failed") < 0 && lower.indexOf("error") < 0) return null;
		var symbol = ~/((?:[a-z_][A-Za-z0-9_]*\.)*[A-Z][A-Za-z0-9_]*)\.([A-Za-z_][A-Za-z0-9_]*)/;
		if (!symbol.match(text)) return null;
		var type = symbol.matched(1), member = symbol.matched(2);
		var relative = StringTools.replace(type, ".", "/") + ".hx";
		for (directory in roots()) {
			var file = directory + "/" + relative;
			if (!FileSystem.exists(file)) continue;
			return new BuildDiagnostic(file, memberLine(file, member), 0);
		}
		return null;
	}

	static function memberLine(file:String, member:String):Int {
		try {
			var lines = File.getContent(file).split("\n");
			for (index in 0...lines.length)
				if (lines[index].indexOf("function " + member + "(") >= 0 || lines[index].indexOf("var " + member) >= 0
					|| lines[index].indexOf("final " + member) >= 0)
					return index;
		} catch (_:Dynamic) {}
		return 0;
	}

	/** The project's source roots and those of the packages it depends on by path, from the haxeon.json manifests. */
	function roots():Array<String> {
		var known = sourceRoots;
		if (known != null) return known;
		var result:Array<String> = [];
		addRoots(projectRoot, 0, result);
		if (result.length == 0) result = [projectRoot + "/src", projectRoot];
		sourceRoots = result;
		return result;
	}

	static function addRoots(directory:String, depth:Int, result:Array<String>):Void {
		var manifest:Dynamic = null;
		try manifest = haxe.Json.parse(File.getContent(directory + "/haxeon.json")) catch (_:Dynamic) {}
		if (manifest == null) return;
		var declared:Null<Array<Dynamic>> = manifest.sourceRoots;
		if (declared != null) for (item in declared) {
			var candidate = haxe.io.Path.normalize(directory + "/" + Std.string(item));
			if (!result.contains(candidate)) result.push(candidate);
		}
		var dependencies:Dynamic = manifest.dependencies;
		if (depth > 0 || dependencies == null) return;
		try for (name in Reflect.fields(dependencies)) {
			var dependency:Dynamic = Reflect.field(dependencies, name);
			if (dependency != null && Std.isOfType(dependency.path, String))
				addRoots(haxe.io.Path.normalize(directory + "/" + Std.string(dependency.path)), depth + 1, result);
		} catch (_:Dynamic) {}
	}
}
