package ui;

import nativekit.ffi.NativeKitTypes;
import haxe.io.Bytes;

/** Which watch registrations a file event may have invalidated. */
enum RearmScope {
	/** Edits and additions never invalidate a registration. */
	Nothing;
	/** Changes were missed in an overflow, so every registration is re-armed. */
	Everything;
	/** A directory at this path was removed or moved, or needs a rescan. */
	Below(path:String);
}

/** Decodes NativeKit file-change events and compares the paths they report. */
class FileWatchEvents {
	static inline final HEADER_BYTES = 28;

	/** The changed path, or null when the payload carries none. */
	public static function changedPath(data:Bytes):Null<String> {
		if (data == null || data.length < HEADER_BYTES) return null;
		var header:FileChangedEvent = data;
		return pathAt(data, header.get_path_offset(), header.get_path_length());
	}

	/** The registrations a FileChanged or FileWatchOverflow event may have invalidated. */
	public static function rearmScope(kind:EventKind, data:Bytes):RearmScope {
		if (kind == EventKind.FileWatchOverflow) return Everything;
		if (data == null || data.length < HEADER_BYTES) return Nothing;
		var header:FileChangedEvent = data;
		var change = header.get_change_type();
		var rescan = (header.get_flags() & FileEventFlags.RescanRequired) != 0;
		var removal = (change == FileChangeType.Removed || change == FileChangeType.Moved)
			&& header.get_item_kind() != FileItemKind.File;
		if (!rescan && !removal) return Nothing;
		var path = change == FileChangeType.Moved
			? pathAt(data, header.get_old_path_offset(), header.get_old_path_length())
			: pathAt(data, header.get_path_offset(), header.get_path_length());
		return path == null ? Everything : Below(path);
	}

	/** Whether a registration at `path` falls within `scope`. */
	public static function covers(scope:RearmScope, path:String):Bool {
		return switch scope {
			case Nothing: false;
			case Everything: true;
			case Below(parent): within(parent, path);
		};
	}

	/** Whether `child` is `parent` or below it. Event paths are not canonical, so both are normalized. */
	public static function within(parent:String, child:String):Bool {
		var left = pathKey(parent), right = pathKey(child);
		return left == right || StringTools.startsWith(right, StringTools.endsWith(left, "/") ? left : left + "/");
	}

	public static function pathKey(path:String):String {
		var normalized = StringTools.replace(path, "\\", "/");
		while (normalized.length > 1 && StringTools.endsWith(normalized, "/")) normalized = normalized.substring(0, normalized.length - 1);
		return Sys.systemName() == "Windows" ? normalized.toLowerCase() : normalized;
	}

	static function pathAt(data:Bytes, offset:Int, length:Int):Null<String> {
		if (offset < HEADER_BYTES || length < 0 || offset + length > data.length) return null;
		return data.getString(offset, length);
	}
}
