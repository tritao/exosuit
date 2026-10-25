package ui;

import haxeon.platform.NativeKitError;
import haxeon.platform.NativeKitEvents;
import haxeon.platform.NativeKitFileWatch;

/** Observes visited directories so stable explorers need no filesystem scans. */
class ExplorerDirectoryWatch {
	final model:DirectoryTreeModel;
	var watch:Null<NativeKitFileWatch>;

	public function new(model:DirectoryTreeModel, events:NativeKitEvents) {
		this.model = model;
		try {
			watch = NativeKitFileWatch.create(events, onEvent);
			model.observeDirectory = addDirectory;
			for (path in model.visitedDirectories()) addDirectory(path);
			model.watchChanges = watch != null;
		} catch (_:NativeKitError) {
			// Platforms without file watching keep the polling fallback.
			dispose();
		}
	}

	function onEvent(event:FileWatchEvent):Void {
		switch event {
			case Changed(_) | Overflow | Lost(_): model.markChanged();
			case Failed(_): dispose();
			case Ready:
		}
	}

	function addDirectory(path:String):Void {
		var current = watch;
		if (current == null) return;
		try {
			if (!current.add(path, false)) return;
		} catch (_:NativeKitError) {
			// Unsupported paths retain the polling fallback.
			dispose();
			return;
		}
		// Rescan this listing after registration to close the initial-read/watch gap.
		model.refreshDirectory(path);
	}

	public function dispose():Void {
		model.watchChanges = false;
		model.observeDirectory = null;
		if (watch != null) watch.dispose();
		watch = null;
	}
}
