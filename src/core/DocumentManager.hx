package core;

import editor.Document;
import editor.LoadedFile;
import sys.thread.Mutex;
import syntax.SyntaxRegistry;
import workspace.FileSystemService;
import workspace.EditorFileSystem;

class DocumentManager {
	public final documents:Array<Document> = [];
	public var externalRevision(default, null):Int = 0;
	public final syntaxes:SyntaxRegistry;
	public final fileSystem:EditorFileSystem;
	/** Files being read on worker threads, by normalized path, with everyone waiting for each. */
	final loading:Map<String, Array<(Null<Document>, Null<Dynamic>)->Void>> = [];
	final loadedMutex = new Mutex();
	final loaded:Array<{path:String, file:Null<LoadedFile>, error:Null<Dynamic>}> = [];

	public function new(syntaxes:SyntaxRegistry, ?fileSystem:EditorFileSystem) {
		this.syntaxes = syntaxes;
		this.fileSystem = fileSystem == null ? new FileSystemService() : fileSystem;
	}

	public function open(path:String):Document {
		for (document in documents)
			if (document.path != null && document.path == path)
				return document;
		var normalized = fileSystem.normalize(path);
		for (document in documents)
			if (document.path != null && document.path == normalized) return document;
		var document = Document.open(normalized, syntaxes, fileSystem);
		documents.push(document);
		return document;
	}

	/**
		Opens a file with its reading and preparation (Document.load) on another thread, which for a large file is most of
		the cost, and calls `done` on the UI thread, from poll, with the document or the error that opening it failed with.
		A document already open is passed at once; opening a file again while it loads waits for the same load.
	**/
	public function openInBackground(path:String, done:(Null<Document>, Null<Dynamic>)->Void):Void {
		var normalized:String;
		try normalized = fileSystem.normalize(path) catch (error:Dynamic) {
			done(null, error);
			return;
		}
		for (document in documents)
			if (document.path == normalized) {
				done(document, null);
				return;
			}
		var waiting = loading.get(normalized);
		if (waiting != null) {
			waiting.push(done);
			return;
		}
		loading.set(normalized, [done]);
		var service = fileSystem;
		haxeon.Threads.create("exo.document.load", function() {
			var file:Null<LoadedFile> = null, failure:Null<Dynamic> = null;
			try file = Document.load(normalized, service) catch (error:Dynamic) failure = error;
			loadedMutex.acquire();
			loaded.push({path: normalized, file: file, error: failure});
			loadedMutex.release();
		});
	}

	/** True while a background open has not been delivered. */
	public function loadingInBackground():Bool
		return loading.keys().hasNext();

	/** Delivers the files that finished loading in the background; the application calls it on the UI thread. */
	public function poll():Void {
		if (!loadingInBackground()) return;
		loadedMutex.acquire();
		var ready = loaded.copy();
		loaded.resize(0);
		loadedMutex.release();
		for (result in ready) {
			var waiting = loading.get(result.path);
			loading.remove(result.path);
			if (waiting == null) continue;
			var document:Null<Document> = null;
			var file = result.file;
			if (file != null) {
				// Opened directly in the meantime: that document wins, and this read is dropped.
				for (existing in documents) if (existing.path == result.path) document = existing;
				if (document == null) {
					document = Document.fromLoaded(file, syntaxes);
					documents.push(document);
				}
			}
			for (done in waiting) done(document, result.error);
		}
	}

	public function createUntitled():Document {
		var document = Document.untitled(syntaxes, fileSystem);
		documents.push(document);
		return document;
	}

	public function restoreRecovered(recoveryId:String, title:String, path:Null<String>, text:String):Document {
		for (document in documents) if (document.recoveryId == recoveryId) return document;
		if (path != null) {
			var document = open(path);
			document.acceptRecoveredText(text);
			return document;
		}
		var document = Document.untitled(syntaxes, fileSystem, recoveryId, title);
		document.acceptRecoveredText(text);
		documents.push(document);
		return document;
	}

	public function saveAs(document:Document, destination:String, overwrite:Bool = false):Bool {
		try {
			var normalized = fileSystem.normalize(destination);
			for (existing in documents)
				if (existing != document && existing.path != null && existing.path == normalized) return false;
			if (fileSystem.exists(normalized) && !overwrite) return false;
			return document.saveAs(normalized);
		} catch (error:Dynamic) {
			return false;
		}
	}

	public function rename(document:Document, destination:String):Bool {
		if (!document.hasBackingPath()) return false;
		var normalized = fileSystem.normalize(destination);
		for (existing in documents) if (existing != document && existing.path == normalized) return false;
		if (!fileSystem.rename(document.requirePath(), normalized)) return false;
		document.setPath(normalized);
		return true;
	}

	public function reconcileRename(source:String, destination:String):Array<Document> {
		var changed:Array<Document> = [], prefix = source + "/";
		for (document in documents)
			if (document.path == source || document.path != null && StringTools.startsWith(document.path, prefix)) {
				var suffix = document.path == source ? "" : document.path.substring(source.length);
				document.setPath(destination + suffix);
				changed.push(document);
			}
		return changed;
	}

	public function reconcileTrash(source:String):Array<Document> {
		var changed:Array<Document> = [], prefix = source + "/";
		for (document in documents)
			if (document.path == source || document.path != null && StringTools.startsWith(document.path, prefix)) {
				document.detachBacking();
				changed.push(document);
			}
		return changed;
	}

	/** Rereads changed backing files. `externalRevision` changes when a document was reloaded or its external state
		changed, so the presentation can redraw for it. */
	public function checkExternalChanges():Void {
		for (document in documents) {
			var previousState = document.externalState, previousBuffer = document.buffer.stateId;
			if (document.checkExternal() != previousState || document.buffer.stateId != previousBuffer) externalRevision++;
		}
	}

	public function add(document:Document):Document {
		for (existing in documents)
			if (existing == document || document.path != null && existing.path == document.path)
				return existing;
		documents.push(document);
		return document;
	}

	public function close(document:Document, force:Bool = false):Bool {
		if (document.dirty && !force)
			return false;
		if (!documents.remove(document)) return false;
		document.dispose();
		return true;
	}
}
