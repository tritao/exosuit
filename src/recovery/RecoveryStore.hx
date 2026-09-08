package recovery;

import core.Application;
import editor.Document;
import sys.FileSystem;
import workspace.FileSystemService;
import workspace.EditorFileSystem;

class RecoveryStore {
	public static inline final VERSION = 3;
	public static inline final MAX_SNAPSHOTS = 50;
	public final path:String;
	public final diagnostics:Array<String> = [];
	final fileSystem:EditorFileSystem;

	public function new(path:String, ?fileSystem:EditorFileSystem) {
		this.path = path;
		this.fileSystem = fileSystem == null ? new FileSystemService() : fileSystem;
	}

	public function save(application:Application):Bool {
		var snapshots = load();
		if (diagnostics.length > 0) return false;
		for (document in application.documents.documents) {
			if (!document.dirty) continue;
			var index = snapshots.length;
			while (index > 0) {
				index--;
				if (matches(snapshots[index], document)) snapshots.splice(index, 1);
			}
			snapshots.push(new RecoverySnapshot(document.recoveryId, document.title, document.path, document.buffer.text));
		}
		return saveSnapshots(snapshots);
	}

	public function saveSnapshots(snapshots:Array<RecoverySnapshot>):Bool {
		if (!ensureParent(path)) return false;
		var output = "pragtical-recovery=" + VERSION + "\n";
		var start = snapshots.length > MAX_SNAPSHOTS ? snapshots.length - MAX_SNAPSHOTS : 0;
		for (index in start...snapshots.length) {
			var snapshot = snapshots[index];
			var recoveredPath = snapshot.path == null ? "" : snapshot.path;
			output += snapshot.id.length + ":" + snapshot.title.length + ":" + recoveredPath.length + ":" + snapshot.text.length + ":"
				+ (snapshot.path == null ? "0" : "1") + ":" + snapshot.id + snapshot.title + recoveredPath + snapshot.text;
		}
		return fileSystem.writeAtomic(path, output);
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
		diagnostics.resize(0);
		if (!fileSystem.exists(path) || fileSystem.isDirectory(path)) return [];
		try {
			return decode(fileSystem.read(path));
		} catch (error:Dynamic) {
			var quarantined = quarantine();
			diagnostics.push(quarantined == null
				? "Could not read recovery data: " + Std.string(error)
				: 'Incompatible recovery data was preserved at "$quarantined"');
			return [];
		}
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
