package search;

import sys.FileSystem;
import workspace.EditorFileSystem;
import workspace.FileSystemService;

/** Retains the complete pre-write contents of the most recent disk replacement batch. */
class ReplacementBackupStore {
	public static inline final VERSION = 1;
	public final path:String;
	final fileSystem:EditorFileSystem;

	public function new(path:String, ?fileSystem:EditorFileSystem) {
		this.path = path;
		this.fileSystem = fileSystem == null ? new FileSystemService() : fileSystem;
	}

	public function save(files:Array<ReplacementBackup>):Bool {
		if (!ensureParent(path)) return false;
		var output = "pragtical-replacement-backup=" + VERSION + "\n";
		for (file in files)
			output += file.path.length + ":" + file.text.length + ":" + file.expectedCurrent.length + ":" + file.matchCount + ":"
				+ file.path + file.text + file.expectedCurrent;
		return fileSystem.writeAtomic(path, output);
	}

	public function load():Array<ReplacementBackup> {
		if (!fileSystem.exists(path) || fileSystem.isDirectory(path)) return [];
		return decode(fileSystem.read(path));
	}

	public static function decode(content:String):Array<ReplacementBackup> {
		var marker = "pragtical-replacement-backup=" + VERSION + "\n";
		if (!StringTools.startsWith(content, marker)) throw "unsupported replacement backup version";
		var result:Array<ReplacementBackup> = [], offset = marker.length;
		while (offset < content.length) {
			var lengths:Array<Int> = [];
			for (field in 0...4) {
				var separator = content.indexOf(":", offset);
				if (separator < 0) throw "corrupt replacement backup lengths";
				lengths.push(Std.parseInt(content.substring(offset, separator)) ?? 0);
				offset = separator + 1;
			}
			var pathLength = lengths[0], textLength = lengths[1], expectedLength = lengths[2], matchCount = lengths[3];
			if (pathLength < 0 || textLength < 0 || expectedLength < 0 || matchCount < 0
				|| offset + pathLength + textLength + expectedLength > content.length)
				throw "corrupt replacement backup payload";
			var path = content.substr(offset, pathLength);
			offset += pathLength;
			var text = content.substr(offset, textLength);
			offset += textLength;
			var expectedCurrent = content.substr(offset, expectedLength);
			offset += expectedLength;
			result.push(new ReplacementBackup(path, text, expectedCurrent, matchCount));
		}
		return result;
	}

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
