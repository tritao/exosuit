package ui;

import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitTypes;
import NativeKitEvents;
import NativeKitEvents.NativeKitEventSubscription;

/** Observes visited directories so stable explorers need no filesystem scans. */
class ExplorerDirectoryWatch {
	final model:DirectoryTreeModel;
	var watch:Null<OwnedFileWatch>;
	var subscription:Null<NativeKitEventSubscription>;
	final registered:Map<String, Bool> = [];

	public function new(model:DirectoryTreeModel, events:NativeKitEvents) {
		this.model = model;
		try {
			var options = new FileWatchOptions();
			options.set_struct_size(24);
			var result = NativeKit.nk_file_watch_create(options);
			if (result.status != Result.Ok) return;
			watch = result.out_watch;
			subscription = events.listen(function(event) {
				switch event {
					case Raw(kind, source, _, _, _, _, _) if (watch != null && source.rawValue() == watch.borrow().rawValue() &&
						(kind == EventKind.FileChanged || kind == EventKind.FileWatchOverflow)):
						model.markChanged();
						// Re-arm watches after moves/removals; inaccessible directories fall back to polling.
						for (path in registered.keys()) {
							if (watch == null) break;
							if (NativeKit.nk_file_watch_add_directory(watch.borrow(), path, false) != Result.Ok) dispose();
						}
					case _:
				}
			});
			model.observeDirectory = addDirectory;
			for (path in model.visitedDirectories()) addDirectory(path);
			model.watchChanges = watch != null;
		} catch (_:Dynamic) {
			dispose();
		}
	}

	function addDirectory(path:String):Void {
		if (watch == null || registered.exists(path)) return;
		if (NativeKit.nk_file_watch_add_directory(watch.borrow(), path, false) != Result.Ok) {
			// Unsupported paths retain the polling fallback.
			dispose();
			return;
		}
		registered.set(path, true);
		// Rescan after registration to close the gap between the initial read and the watch.
		model.markChanged();
	}

	public function dispose():Void {
		model.watchChanges = false;
		model.observeDirectory = null;
		if (subscription != null) subscription.dispose();
		subscription = null;
		if (watch != null) watch.close();
		watch = null;
	}
}
