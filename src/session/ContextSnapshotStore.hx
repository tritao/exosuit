package session;

import haxe.crypto.Sha256;
import sys.FileSystem;
import sys.io.File;

/** One saved context: its key and the layout lines the workbench host restores it from. */
class ContextSnapshot {
	public final key:String;
	public final lines:Array<String>;
	public final written:Float;
	public function new(key:String, lines:Array<String>, written:Float) {
		this.key = key; this.lines = lines; this.written = written;
	}
}

/** The files one `request` has to write or delete, and what happened to them. Built on the main thread, run on any. */
private class SyncJob {
	public final folder:String;
	public final writes:Array<{key:String, lines:Array<String>}> = [];
	/** Files to delete, each with the content this window last read or wrote: a file that differs is another window's. */
	public final deletes:Array<{key:String, expected:String}> = [];
	public final wrote:Array<{key:String, text:String}> = [];
	public final removed:Array<String> = [];
	/** Contexts whose file another window rewrote since this one saw it. */
	public final foreign:Array<String> = [];
	public final errors:Map<String, String> = [];
	public final done = new sys.thread.Lock();

	public function new(folder:String) this.folder = folder;

	public function isEmpty():Bool return writes.length == 0 && deletes.length == 0;

	public function run():Void {
		for (entry in writes) {
			try {
				if (!FileSystem.exists(folder)) FileSystem.createDirectory(folder);
				var text = haxe.Json.stringify({version: ContextSnapshotStore.VERSION, key: entry.key, written: Date.now().getTime(), layout: entry.lines});
				if (text.length > ContextSnapshotStore.MAX_FILE_CHARS) throw "the layout is larger than " + ContextSnapshotStore.MAX_FILE_CHARS + " characters";
				sys.io.AtomicFile.write(folder + "/" + ContextSnapshotStore.fileName(entry.key), text);
				wrote.push({key: entry.key, text: ContextSnapshotStore.encodeLines(entry.lines)});
			} catch (error:Dynamic) {
				errors.set(entry.key, Std.string(error));
			}
		}
		for (entry in deletes) {
			var path = folder + "/" + ContextSnapshotStore.fileName(entry.key);
			try {
				if (!FileSystem.exists(path)) { removed.push(entry.key); continue; }
				// Compare and delete: another window may have rewritten the file since this one read or wrote it.
				var current = ContextSnapshotStore.readFile(path);
				if (current == null) continue; // unreadable: leave it, it may be mid-write elsewhere
				if (ContextSnapshotStore.encodeLines(current.lines) != entry.expected) { foreign.push(entry.key); continue; }
				FileSystem.deleteFile(path);
				removed.push(entry.key);
			} catch (error:Dynamic) {
				errors.set(entry.key, Std.string(error));
			}
		}
	}
}

/**
	One file per context (`machine/workspace/group`) in a folder beside session.conf, each written atomically.
	A window writes only the contexts whose content changed since it last read or wrote them, so two windows never
	overwrite each other's other groups, and the most recent writer of a group wins for that group. The window-level
	chrome stays in session.conf.

	File name: `<readable prefix>-<sha256 of the key>.json`. The key itself is inside the file, so the name only has to be
	stable, filesystem-safe on every platform and case-insensitive-safe.

	Writing never happens on the frame that asks for it: `request` keeps the latest contexts, `pump` (once per tick)
	plans the changes and hands the file work to a background thread, one job at a time, and collects the result on a
	later tick. `sync` is the blocking form used at shutdown.
**/
class ContextSnapshotStore {
	public static inline final VERSION = 1;
	public static inline final MAX_LINES = 20000;
	/** Larger files are neither read nor written; real layouts are a few KB, a hundred tabs about 30 KB. */
	public static inline final MAX_FILE_CHARS = 4194304;
	/** More files than this in the folder are ignored (the first by name are read). */
	public static inline final MAX_FILES = 200;
	public final folder:String;
	/** Reports a failed write or delete, once per context until it succeeds again: (title, message). */
	public var onError:Null<(String, String)->Void>;
	/** Per key, the encoded lines this window last read or wrote; only differences are written. */
	final known:Map<String, String> = [];
	final reported:Map<String, Bool> = [];
	var latest:Null<Map<String, Array<String>>>;
	var running:Null<SyncJob>;

	public function new(folder:String) this.folder = folder;

	public static function fileName(key:String):String {
		var prefix = new StringBuf();
		for (index in 0...key.length) {
			if (prefix.length >= 40) break;
			var code = key.charCodeAt(index);
			var plain = code >= 97 && code <= 122 || code >= 65 && code <= 90 || code >= 48 && code <= 57 || code == 45;
			prefix.addChar(plain ? code : 95);
		}
		return prefix.toString() + "-" + Sha256.encode(key).substr(0, 16) + ".json";
	}

	public function pathFor(key:String):String return folder + "/" + fileName(key);

	public static function encodeLines(lines:Array<String>):String return lines.join("\n");

	/** Writes `lines` for `key` now, on this thread, whether or not they changed. */
	public function write(key:String, lines:Array<String>):Bool {
		var job = new SyncJob(folder);
		if (key.length > 0) job.writes.push({key: key, lines: lines});
		job.run();
		apply(job);
		return job.wrote.length == 1;
	}

	/** Remembers the contexts to bring the folder in line with; nothing is read or written until `pump`. */
	public function request(contexts:Map<String, Array<String>>):Void latest = contexts;

	/** Call once per tick on the main thread: collects a finished job, then starts the next if something was requested. */
	public function pump():Void {
		collect(false);
		var contexts = latest;
		if (running != null || contexts == null) return;
		latest = null;
		var job = plan(contexts);
		if (job.isEmpty()) return;
		running = job;
		haxeon.Threads.create("exo.context.save", function() {
			job.run();
			job.done.release();
		});
	}

	/** True while a background job runs or a request waits for one. */
	public function busy():Bool return running != null || latest != null;

	function collect(wait:Bool):Void {
		var job = running;
		if (job == null) return;
		if (!job.done.wait(wait ? null : 0.0)) return;
		running = null;
		apply(job);
	}

	function plan(contexts:Map<String, Array<String>>):SyncJob {
		var job = new SyncJob(folder);
		for (key in contexts.keys()) {
			var lines = contexts.get(key);
			if (key.length == 0 || lines == null || known.get(key) == encodeLines(lines)) continue;
			job.writes.push({key: key, lines: lines});
		}
		for (key in known.keys()) if (!contexts.exists(key)) job.deletes.push({key: key, expected: known.get(key)});
		return job;
	}

	function apply(job:SyncJob):Void {
		for (entry in job.wrote) { known.set(entry.key, entry.text); reported.remove(entry.key); }
		for (key in job.removed) { known.remove(key); reported.remove(key); }
		for (key in job.foreign) known.remove(key);
		for (key in job.errors.keys()) {
			// Failed work stays different from `known`, so the next request retries it; the user hears of it once.
			if (reported.exists(key)) continue;
			reported.set(key, true);
			if (onError != null) onError("session", "Could not save the tabs of " + key + ": " + job.errors.get(key));
		}
	}

	/**
		Blocking sync: waits for a job in progress, then brings the folder in line with `contexts` on this thread.
		Used at shutdown and by tests. Returns how many files were written or deleted.
	**/
	public function sync(contexts:Map<String, Array<String>>):Int {
		collect(true);
		latest = null;
		var job = plan(contexts);
		job.run();
		apply(job);
		return job.wrote.length + job.removed.length;
	}

	public function hasFiles():Bool return jsonNames().length > 0;

	function jsonNames():Array<String> {
		var result:Array<String> = [];
		if (!FileSystem.exists(folder) || !FileSystem.isDirectory(folder)) return result;
		var names = FileSystem.readDirectory(folder);
		names.sort(Reflect.compare);
		for (name in names) if (StringTools.endsWith(name, ".json") && result.length < MAX_FILES) result.push(name);
		return result;
	}

	/** Every valid snapshot in the folder (at most `MAX_FILES` files). A damaged file is skipped and left where it is. */
	public function readAll():Array<ContextSnapshot> {
		var result:Array<ContextSnapshot> = [];
		for (name in jsonNames()) {
			var snapshot = readFile(folder + "/" + name);
			if (snapshot == null) continue;
			known.set(snapshot.key, encodeLines(snapshot.lines));
			result.push(snapshot);
		}
		return result;
	}

	public static function readFile(path:String):Null<ContextSnapshot> {
		try {
			if (FileSystem.isDirectory(path)) return null;
			var metadata = FileSystem.metadata(path);
			if (metadata == null || metadata.size > MAX_FILE_CHARS) return null;
			var data:Dynamic = haxe.Json.parse(File.getContent(path));
			if (data == null || data.version != VERSION || !Std.isOfType(data.key, String) || !Std.isOfType(data.layout, Array)) return null;
			var key:String = data.key, raw:Array<Dynamic> = data.layout;
			if (key.length == 0 || key.length > 4096 || raw.length > MAX_LINES) return null;
			var lines:Array<String> = [];
			for (entry in raw) {
				if (!Std.isOfType(entry, String)) return null;
				var line:String = entry;
				if (StringTools.startsWith(line, "Z\t") || !WorkspaceSession.validLayout(line)) return null;
				lines.push(line);
			}
			if (!ContextLayoutStore.complete(lines)) return null;
			var written:Float = Std.isOfType(data.written, Float) ? data.written : 0;
			return new ContextSnapshot(key, lines, written);
		} catch (_:Dynamic) {
			return null;
		}
	}
}
