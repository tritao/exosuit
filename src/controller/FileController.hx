package controller;

import command.CommandContext;
import command.CommandRegistry;
import commandview.CommandViewProvider;
import core.DocumentManager;
import core.WorkbenchHost;
import editor.Document;
import feedback.ConfirmationService;
import recovery.RecoveryStore;
import workspace.FileOperations;
import workspace.Workspace;

class FileController {
	public var quitReady(default, null):Bool = false;
	/** A graphical host supplies an asynchronous destination chooser. */
	public var chooseSaveDestination:Null<(Document, (Null<String>, Bool)->Void)->Void>;
	var saveAsPending:Bool = false;

	final documents:DocumentManager;
	final workspace:Workspace;
	final operations:FileOperations;
	final root:WorkbenchHost;
	final context:CommandContext;
	final confirmations:ConfirmationService;
	final recovery:RecoveryStore;
	final openDocument:String->Void;
	final newDocument:Void->Void;
	final saveRecovery:Void->Void;
	final reportError:(String, String)->Void;
	final reportInformation:String->Void;
	var closeDocuments:Array<Document> = [];
	var closeIndex:Int = 0;
	var closeAction:Null<Void->Bool>;
	var closePending:Bool = false;

	public function new(documents:DocumentManager, workspace:Workspace, operations:FileOperations, root:WorkbenchHost, context:CommandContext,
		commands:CommandRegistry, confirmations:ConfirmationService, recovery:RecoveryStore, openDocument:String->Void,
		newDocument:Void->Void, saveRecovery:Void->Void, reportError:(String, String)->Void, reportInformation:String->Void) {
		this.documents = documents;
		this.workspace = workspace;
		this.operations = operations;
		this.root = root;
		this.context = context;
		this.confirmations = confirmations;
		this.recovery = recovery;
		this.openDocument = openDocument;
		this.newDocument = newDocument;
		this.saveRecovery = saveRecovery;
		this.reportError = reportError;
		this.reportInformation = reportInformation;
		installCommands(commands);
	}

	public function requestCloseActiveTab():Bool
		return requestCloseTab(root.documentsLostByClosingActiveTab(), function() return root.closeActiveTab(true));

	/** Confirm losses before closing a stable tab target supplied by a UI host. */
	public function requestCloseTab(documentsLost:Array<Document>, close:Void->Bool):Bool
		return beginClose(documentsLost, close);

	public function requestCloseActivePane():Bool {
		if (!root.canCloseActivePane()) return false;
		return beginClose(root.documentsLostByClosingActivePane(), function() return root.closeActivePane(true));
	}

	public function requestQuit(?onReady:Void->Void):Bool {
		if (quitReady) {
			if (onReady != null) onReady();
			return true;
		}
		var dirty:Array<Document> = [];
		for (document in documents.documents)
			if (document.dirty && dirty.indexOf(document) < 0) dirty.push(document);
		return beginClose(dirty, function() {
			// Recovery may have run while earlier documents were being confirmed.
			for (document in closeDocuments) recovery.forget(document);
			quitReady = true;
			if (onReady != null) onReady();
			return true;
		});
	}

	public function openSaveAs(document:Document, ?onSuccess:Void->Void, ?onCancel:Void->Void):Void {
		if (chooseSaveDestination != null) {
			if (saveAsPending) return;
			saveAsPending = true;
			chooseSaveDestination(document, function(destination, overwrite) {
				if (!saveAsPending) return;
				saveAsPending = false;
				if (destination == null) {
					if (onCancel != null) onCancel();
				} else if (documents.saveAs(document, destination, overwrite)) {
					completeSaveAs(document, onSuccess);
				} else {
					reportError("file", 'Could not save as "' + destination + '"; destination may already be open or unwritable');
					if (onCancel != null) onCancel();
				}
			});
			return;
		}
		root.openCommandView(new CommandViewProvider("Save As: ", [], function(query) {}, function(entry, destination, backwards) {
			if (documents.saveAs(document, destination)) {
				completeSaveAs(document, onSuccess);
			} else if (workspace.fileSystem.exists(destination)) {
				root.openCommandView(new CommandViewProvider('Type overwrite to replace "$destination": ', [], function(query) {},
					function(entry, answer, backwards) {
						if (answer == "overwrite" && documents.saveAs(document, destination, true))
							completeSaveAs(document, onSuccess);
					}, onCancel));
			} else {
				reportError("file", 'Could not save as "$destination"');
				root.closeCommandView();
				if (onCancel != null) onCancel();
			}
		}, onCancel));
	}

	public function openCreateFile():Void {
		root.openCommandView(new CommandViewProvider("New File: ", [], function(query) {}, function(entry, path, backwards) {
			var result = operations.createFile(path);
			if (result.success) {
				workspace.refreshProjects();
				if (result.destination != null) openDocument(result.destination);
			} else reportError("file", 'Could not create file "$path": ' + result.detail);
			root.closeCommandView();
		}));
	}

	public function openCreateFolder():Void {
		root.openCommandView(new CommandViewProvider("New Folder: ", [], function(query) {}, function(entry, path, backwards) {
			var result = operations.createFolder(path);
			if (!result.success) reportError("file", 'Could not create folder "$path": ' + result.detail);
			workspace.refreshProjects();
			root.closeCommandView();
		}));
	}

	public function openRenameFile():Void {
		var source = selectedFileOperationPath();
		if (source == null) return;
		root.openCommandView(new CommandViewProvider("Rename/Move: ", [], function(query) {}, function(entry, destination, backwards) {
			var result = operations.move(source, destination);
			if (!result.success) reportError("file", 'Could not rename "$source": ' + result.detail); else
				for (document in result.documents) root.documentRenamed(document);
			workspace.refreshProjects();
			root.closeCommandView();
		}));
	}

	public function openDeleteFile():Void {
		var path = selectedFileOperationPath();
		if (path == null) return;
		confirmations.choose('Type delete to remove "' + path + '": ', ["delete"], function(answer) {
			var result = operations.remove(path);
			if (result.success) {
				for (document in result.documents) root.documentRenamed(document);
				saveRecovery();
				reportInformation('Moved "$path" to ' + result.destination);
				workspace.refreshProjects();
			} else reportError("file", 'Could not safely delete "$path": ' + result.detail);
			root.closeCommandView();
		});
	}

	function installCommands(commands:CommandRegistry):Void {
		commands.add("doc:save", function(context) {
			var document = context.requireDocument();
			if (!document.hasBackingPath()) {
				openSaveAs(document);
				return;
			}
			if (!document.save()) {
				reportError("file", 'Save blocked for "' + document.path + '": disk changed or write failed');
				if (document.externalState != editor.ExternalState.Current) confirmOverwrite(document);
			} else recovery.forget(document);
		}, context -> activeDocument() != null);
		commands.add("file:new", context -> openCreateFile());
		commands.add("doc:new", function(context) {
			newDocument();
		});
		commands.add("doc:save-as", context -> openSaveAs(context.requireDocument()), context -> activeDocument() != null);
		commands.add("root:close", context -> requestCloseActiveTab(), context -> root.canCloseActiveTab());
		commands.add("root:close-pane", context -> requestCloseActivePane());
		commands.add("folder:new", context -> openCreateFolder());
		commands.add("file:rename", context -> openRenameFile(), context -> selectedFileOperationPath() != null);
		commands.add("file:delete", context -> openDeleteFile(), context -> selectedFileOperationPath() != null);
	}

	function beginClose(candidates:Array<Document>, action:Void->Bool):Bool {
		if (closePending) return false;
		closeDocuments.resize(0);
		for (document in candidates)
			if (document.dirty && closeDocuments.indexOf(document) < 0) closeDocuments.push(document);
		closeIndex = 0;
		closeAction = action;
		closePending = true;
		continueClose();
		return true;
	}

	function continueClose():Void {
		if (!closePending) return;
		if (closeIndex >= closeDocuments.length) {
			var action = closeAction;
			closePending = false;
			closeAction = null;
			root.closeCommandView();
			if (action != null) action();
			return;
		}
		var document = closeDocuments[closeIndex];
		confirmations.saveChanges(document.title,
			function(answer) {
				if (answer == "cancel") cancelClose();
				else if (answer == "discard") advanceClose(document);
				else if (answer == "save") {
					if (document.hasBackingPath()) {
						if (!document.save()) {
							reportError("file", 'Could not save "' + document.title + '"; close cancelled');
							cancelClose();
						} else advanceClose(document);
					} else openSaveAs(document, function() {
						closeIndex++;
						continueClose();
					}, cancelClose);
				}
			}, cancelClose);
	}

	function advanceClose(document:Document):Void {
		recovery.forget(document);
		closeIndex++;
		continueClose();
	}

	function cancelClose():Void {
		closePending = false;
		closeDocuments.resize(0);
		closeAction = null;
		root.closeCommandView();
	}

	function completeSaveAs(document:Document, onSuccess:Null<Void->Void>):Void {
		root.documentRenamed(document);
		recovery.forget(document);
		root.closeCommandView();
		if (onSuccess != null) onSuccess();
	}

	function confirmOverwrite(document:Document):Void {
		confirmations.choose("Disk changed. Type overwrite to save, or Escape to cancel: ", ["overwrite"], function(answer) {
			if (document.save(true)) {
				recovery.forget(document);
				reportInformation("Saved " + document.path);
			} else reportError("file", "Could not save " + document.path);
			root.closeCommandView();
		});
	}

	function selectedFileOperationPath():Null<String> {
		var focused = root.focusedFilePath();
		if (focused != null) return focused;
		var document = activeDocument();
		return document == null || !document.hasBackingPath() ? null : document.requirePath();
	}

	function activeDocument():Null<Document> {
		var view = context.activeView();
		return view == null ? null : view.getDocument();
	}
}
