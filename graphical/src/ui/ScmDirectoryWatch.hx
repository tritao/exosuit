package ui;

import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitTypes;
import haxe.io.Bytes;
import haxeon.platform.NativeKitEvents;
import haxeon.platform.NativeKitEvents.NativeKitEventSubscription;
import scm.ScmService;

/** Bridges native worktree/Git metadata watches into the shared SCM service. */
class ScmDirectoryWatch {
	final scm:ScmService;
	final states:Map<String, ScmWatchState> = [];
	final byHandle:Map<Int, ScmWatchState> = [];
	final subscription:NativeKitEventSubscription;
	var disposed:Bool = false;
	public var lastError(default, null):Null<String>;

	public function new(scm:ScmService, events:NativeKitEvents) {
		this.scm = scm;
		subscription = events.listen(onEvent);
	}

	/** Replaces watches for one project root; unsupported watches use SCM polling. */
	public function update(root:String, paths:Array<String>):Void {
		if (disposed) return;
		lastError = null;
		var key = pathKey(root), previous = states.get(key);
		if (previous != null) disposeState(previous);
		scm.setWatchAvailable(root, false);
		if (paths == null || paths.length == 0) return;

		var options = new FileWatchOptions();
		options.set_struct_size(24);
		var created = NativeKit.nk_file_watch_create(options);
		if (created.status != Result.Ok) {
			lastError = nativeError("Creating the SCM file watcher failed");
			return;
		}
		var watch = created.out_watch;
		var state = new ScmWatchState(key, root, watch);
		states.set(key, state);
		byHandle.set(watch.borrow().rawValue(), state);

		var selected:Array<String> = [];
		for (path in paths) {
			var covered = false;
			for (parent in selected) if (within(parent, path)) { covered = true; break; }
			if (covered) continue;
			if (NativeKit.nk_file_watch_add_directory(watch.borrow(), path, true) != Result.Ok) {
				lastError = nativeError("Watching " + path + " failed");
				disposeState(state);
				return;
			}
			selected.push(path);
		}
		state.paths = selected;
		scm.setWatchAvailable(root, true);
	}

	public function isWatching(root:String):Bool {
		var state = states.get(pathKey(root));
		return state != null && state.watch != null;
	}

	public function dispose():Void {
		if (disposed) return;
		disposed = true;
		subscription.dispose();
		for (state in [for (value in states) value]) disposeState(state);
		states.clear();
		byHandle.clear();
	}

	function onEvent(event:haxeon.platform.NativeKitEventValue):Void {
		switch event {
			case Raw(kind, source, _, _, _, _, data) if (kind == EventKind.FileChanged || kind == EventKind.FileWatchOverflow):
				var state = byHandle.get(source.rawValue());
				if (state == null || state.watch == null) return;
				var overflow = kind == EventKind.FileWatchOverflow;
				scm.notifyChanged(state.root, overflow, null, overflow ? null : changedPath(data));
				for (path in state.paths) {
					if (state.watch == null) break;
					if (NativeKit.nk_file_watch_add_directory(state.watch.borrow(), path, true) != Result.Ok) {
						lastError = nativeError("Re-arming the SCM watch for " + path + " failed");
						disposeState(state);
						break;
					}
				}
			case _:
		}
	}

	static function changedPath(data:Bytes):Null<String> {
		if (data == null || data.length < 28) return null;
		var header:FileChangedEvent = data;
		var offset = header.get_path_offset(), length = header.get_path_length();
		if (offset < 28 || length < 0 || offset + length > data.length) return null;
		return data.getString(offset, length);
	}

	function disposeState(state:ScmWatchState):Void {
		var current = states.get(state.key);
		if (current == state) states.remove(state.key);
		var watch = state.watch;
		state.watch = null;
		scm.setWatchAvailable(state.root, false);
		if (watch != null) {
			byHandle.remove(watch.borrow().rawValue());
			watch.close();
		}
		state.paths.resize(0);
	}

	static function nativeError(message:String):String {
		var detail = NativeKit.nk_last_error();
		return detail == null || detail.length == 0 ? message : message + ": " + detail;
	}

	static function within(parent:String, child:String):Bool {
		var left = pathKey(parent), right = pathKey(child);
		return left == right || StringTools.startsWith(right, StringTools.endsWith(left, "/") ? left : left + "/");
	}

	static function pathKey(path:String):String {
		var normalized = StringTools.replace(path, "\\", "/");
		while (normalized.length > 1 && StringTools.endsWith(normalized, "/")) normalized = normalized.substring(0, normalized.length - 1);
		return Sys.systemName() == "Windows" ? normalized.toLowerCase() : normalized;
	}
}

private class ScmWatchState {
	public final key:String;
	public final root:String;
	public var watch:Null<OwnedFileWatch>;
	public var paths:Array<String> = [];

	public function new(key:String, root:String, watch:OwnedFileWatch) {
		this.key = key;
		this.root = root;
		this.watch = watch;
	}
}
