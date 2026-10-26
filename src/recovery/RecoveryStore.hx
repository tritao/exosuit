package recovery;

import core.Application;
import editor.Document;
import sys.FileSystem;
import workspace.FileSystemService;
import workspace.EditorFileSystem;
import workspace.FileStamp;

class RecoveryStore {
	public static inline final VERSION = 3;
	public static inline final MAX_SNAPSHOTS = 50;
	public final path:String;
	public final diagnostics:Array<String> = [];
	final fileSystem:EditorFileSystem;
	/** The dirty documents and their text states as of the last save, which a save with nothing new skips. */
	var savedSignature:Null<String> = null;
	/** The snapshots the file holds, and its stamp then: load reads it again only when the stamp changes. */
	var cached:Null<Array<RecoverySnapshot>> = null;
	var cachedStamp:Null<FileStamp> = null;
	/** A saveInBackground write in progress on another thread. */
	var writing:Null<RecoveryWrite> = null;

	public function new(path:String, ?fileSystem:EditorFileSystem) {
		this.path = path;
		this.fileSystem = fileSystem == null ? new FileSystemService() : fileSystem;
	}

	public function save(application:Application):Bool {
		var signature = signatureOf(application);
		if (signature == savedSignature) return true;
		var snapshots = snapshotsFor(application);
		if (snapshots == null) return false;
		if (!saveSnapshots(snapshots)) return false;
		savedSignature = signature;
		return true;
	}

	/**
		Saves as save does, but encodes and writes the file on another thread: the periodic save while editing, which for
		a large buffer would otherwise stall typing. A save while the previous write is still running is left for the next
		one, which records the latest state; reads and synchronous saves wait for a write in progress first.
	**/
	public function saveInBackground(application:Application):Void {
		if (!finishWrite(false)) return;
		var signature = signatureOf(application);
		if (signature == savedSignature) return;
		var snapshots = snapshotsFor(application);
		if (snapshots == null || !ensureParent(path)) return;
		var write = new RecoveryWrite(signature, snapshots), files = fileSystem, target = path;
		writing = write;
		haxeon.Threads.create("exo.recovery.save", function() {
			var ok = false;
			try ok = files.writeAtomic(target, encode(write.snapshots)) catch (_:Dynamic) {}
			write.finish(ok);
		});
	}

	/** Collects the result of a background write: waiting for it, or only if it is done. False while one still runs. */
	function finishWrite(wait:Bool):Bool {
		var write = writing;
		if (write == null) return true;
		if (!write.done.wait(wait ? null : 0.0)) return false;
		writing = null;
		if (write.ok) {
			savedSignature = write.signature;
			remember(write.snapshots);
		} else
			cached = null;
		return true;
	}

	/** Waits for a background write in progress, as shutdown must before the process ends. */
	public function flush():Void
		finishWrite(true);

	static function signatureOf(application:Application):String {
		var signature = "";
		for (document in application.documents.documents)
			if (document.dirty) signature += document.recoveryId + "\n" + document.path + "\n" + document.buffer.stateId + "\n";
		return signature;
	}

	/** The snapshots to save: those on file, with each dirty document's replaced by its current text; null if the file
		could not be read. */
	function snapshotsFor(application:Application):Null<Array<RecoverySnapshot>> {
		var snapshots = load();
		if (diagnostics.length > 0) return null;
		for (document in application.documents.documents) {
			if (!document.dirty) continue;
			var index = snapshots.length;
			while (index > 0) {
				index--;
				if (matches(snapshots[index], document)) snapshots.splice(index, 1);
			}
			snapshots.push(new RecoverySnapshot(document.recoveryId, document.title, document.path, document.buffer.text));
		}
		return snapshots;
	}

	public function saveSnapshots(snapshots:Array<RecoverySnapshot>):Bool {
		finishWrite(true);
		savedSignature = null;
		if (!ensureParent(path)) return false;
		if (!fileSystem.writeAtomic(path, encode(snapshots))) {
			cached = null;
			return false;
		}
		remember(snapshots);
		return true;
	}

	/** After writing the file: it holds these snapshots, as of its stamp now. Only another writer changes the stamp. */
	function remember(snapshots:Array<RecoverySnapshot>):Void {
		var start = snapshots.length > MAX_SNAPSHOTS ? snapshots.length - MAX_SNAPSHOTS : 0;
		cached = snapshots.slice(start);
		cachedStamp = fileSystem.stamp(path);
		if (cachedStamp == null) cached = null;
	}

	static function encode(snapshots:Array<RecoverySnapshot>):String {
		var output = new StringBuf();
		output.add("pragtical-recovery=" + VERSION + "\n");
		var start = snapshots.length > MAX_SNAPSHOTS ? snapshots.length - MAX_SNAPSHOTS : 0;
		for (index in start...snapshots.length) {
			var snapshot = snapshots[index];
			var recoveredPath = snapshot.path == null ? "" : snapshot.path;
			output.add(snapshot.id.length + ":" + snapshot.title.length + ":" + recoveredPath.length + ":" + snapshot.text.length + ":"
				+ (snapshot.path == null ? "0" : "1") + ":");
			output.add(snapshot.id);
			output.add(snapshot.title);
			output.add(recoveredPath);
			output.add(snapshot.text);
		}
		return output.toString();
	}

	public function forget(document:Document):Bool {
		var snapshots = load();
		if (diagnostics.length > 0) return false;
		return saveSnapshots([for (snapshot in snapshots) if (!matches(snapshot, document)) snapshot]);
	}

	public function forgetSnapshot(accepted:RecoverySnapshot):Bool {
		var snapshots = load();
		if (diagnostics.length > 0) return false;
		return saveSnapshots([for (snapshot in snapshots) if (!sameSnapshot(snapshot, accepted)) snapshot]);
	}

	public function load():Array<RecoverySnapshot> {
		finishWrite(true);
		diagnostics.resize(0);
		if (!fileSystem.exists(path) || fileSystem.isDirectory(path)) {
			cached = null;
			return [];
		}
		var stamp = fileSystem.stamp(path), known = cached, readAt = Sys.time();
		if (known != null && stamp != null && stamp.equals(cachedStamp)) return known.copy();
		try {
			var snapshots = decode(fileSystem.read(path));
			// Another writer's file vouches for what was read only once it has settled (see FileStamp).
			cached = snapshots.copy();
			cachedStamp = stamp != null && stamp.settledBefore(readAt) ? stamp : null;
			return snapshots;
		} catch (error:Dynamic) {
			cached = null;
			savedSignature = null;
			var quarantined = quarantine();
			diagnostics.push(quarantined == null
				? "Could not read recovery data: " + Std.string(error)
				: 'Incompatible recovery data was preserved at "$quarantined"');
			return [];
		}
	}

	/** Snapshots not already represented by an open document. Session restoration
		uses the same recovery identity, so these are the only snapshots that still
		need the user's attention. */
	public function loadPending(application:Application):Array<RecoverySnapshot> {
		var openIds:Map<String, Bool> = [];
		for (document in application.documents.documents) openIds.set(document.recoveryId, true);
		return [for (snapshot in load()) if (!openIds.exists(snapshot.id)) snapshot];
	}

	public static function decode(content:String):Array<RecoverySnapshot> {
		var marker = "pragtical-recovery=" + VERSION + "\n";
		if (!StringTools.startsWith(content, marker)) throw "unsupported recovery version";
		var result:Array<RecoverySnapshot> = [], offset = marker.length;
		while (offset < content.length) {
			var fields:Array<String> = [];
			for (index in 0...5) {
				var separator = content.indexOf(":", offset);
				if (separator < 0) throw "corrupt recovery lengths";
				fields.push(content.substring(offset, separator));
				offset = separator + 1;
			}
			var idLength = Std.parseInt(fields[0]), titleLength = Std.parseInt(fields[1]), pathLength = Std.parseInt(fields[2]), textLength = Std.parseInt(fields[3]);
			if (Std.string(idLength) != fields[0] || Std.string(titleLength) != fields[1] || Std.string(pathLength) != fields[2]
				|| Std.string(textLength) != fields[3] || (fields[4] != "0" && fields[4] != "1")) throw "corrupt recovery lengths";
			if (idLength < 1 || titleLength < 0 || pathLength < 0 || textLength < 0
				|| offset + idLength + titleLength + pathLength + textLength > content.length)
				throw "corrupt recovery payload";
			var id = content.substr(offset, idLength);
			offset += idLength;
			var title = content.substr(offset, titleLength);
			offset += titleLength;
			var recoveredPath = content.substr(offset, pathLength);
			offset += pathLength;
			var text = content.substr(offset, textLength);
			offset += textLength;
			result.push(new RecoverySnapshot(id, title, fields[4] == "0" ? null : recoveredPath, text));
		}
		return result;
	}

	function quarantine():Null<String> {
		var candidate = path + ".incompatible", suffix = 1;
		while (fileSystem.exists(candidate)) candidate = path + ".incompatible-" + suffix++;
		return fileSystem.rename(path, candidate) ? candidate : null;
	}

	public function restore(application:Application, snapshot:RecoverySnapshot):Bool {
		if (snapshot.path != null && (!fileSystem.exists(snapshot.path) || fileSystem.isDirectory(snapshot.path))) {
			diagnostics.push('Recovery source is missing: "' + snapshot.path + '"');
			return false;
		}
		var document = application.documents.restoreRecovered(snapshot.id, snapshot.title, snapshot.path, snapshot.text);
		application.root.openDocument(document);
		return true;
	}

	static function matches(snapshot:RecoverySnapshot, document:Document):Bool
		return snapshot.id == document.recoveryId || snapshot.path != null && snapshot.path == document.path;

	static function sameSnapshot(left:RecoverySnapshot, right:RecoverySnapshot):Bool
		return left.id == right.id && left.path == right.path && left.text == right.text;

	static function ensureParent(path:String):Bool {
		var separator = path.lastIndexOf("/");
		if (separator <= 0) return true;
		var parent = path.substring(0, separator);
		if (FileSystem.exists(parent)) return FileSystem.isDirectory(parent);
		if (!ensureParent(parent)) return false;
		FileSystem.createDirectory(parent);
		return FileSystem.exists(parent) && FileSystem.isDirectory(parent);
	}
}

/** One background recovery write: what it records, and whether it succeeded once done. */
private class RecoveryWrite {
	public final signature:String;
	public final snapshots:Array<RecoverySnapshot>;
	public final done = new sys.thread.Lock();
	public var ok(default, null):Bool = false;

	public function new(signature:String, snapshots:Array<RecoverySnapshot>) {
		this.signature = signature;
		this.snapshots = snapshots;
	}

	public function finish(succeeded:Bool):Void {
		ok = succeeded;
		done.release();
	}
}
