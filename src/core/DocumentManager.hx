package core;

import editor.Document;
import syntax.SyntaxRegistry;
import workspace.FileSystemService;
import workspace.EditorFileSystem;

class DocumentManager {
	public final documents:Array<Document> = [];
	public final syntaxes:SyntaxRegistry;
	public final fileSystem:EditorFileSystem;

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

	public function checkExternalChanges():Void
		for (document in documents) document.checkExternal();

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
