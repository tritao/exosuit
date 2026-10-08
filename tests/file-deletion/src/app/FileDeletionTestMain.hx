package app;

import core.Application;
import editor.BufferSelection;
import editor.ExternalState;
import platform.Platform;
import testing.model.ModelTextMetrics;
import testing.model.ModelWorkbenchHost;
import view.LayoutKind;
import sys.FileSystem;
import sys.io.File;

/** Exercise deletion through the same controller used by the Explorer menu. */
class FileDeletionTestMain {
	static function main():Int {
		var args = Sys.args();
		require(args.length == 1, "expected deletion fixture directory");
		run(args[0]);
		return 0;
	}
	static function require(value:Bool, message:String):Void { if (!value) throw message; }
	static function confirmDelete(application:Application):Void {
		application.files.openDeleteFile();
		require(application.root.isCommandViewActive(), "deletion confirmation missing");
		application.textInput("delete");
		application.keyPressed(Platform.KEY_ENTER, 0);
	}
	public static function run(directory:String):Void {
		FileSystem.createDirectory(directory);
		var metrics = new ModelTextMetrics("ignored-headlessly.ttf", 15);
		var application = new Application((theme, focus, workspace, settings) ->
			new ModelWorkbenchHost(metrics, theme, focus, workspace, 640, 320, settings));
		var root:ModelWorkbenchHost = cast application.root;
		var prompts = 0;
		var answer = "cancel";
		application.confirmations.saveChangesPrompt = function(_, choose) { prompts++; choose(answer); };

		var cleanPath = directory + "/clean.hx";
		File.saveContent(cleanPath, "class Clean {}\n");
		application.open(cleanPath);
		var clean = application.documents.documents[0];
		root.splitActive(LayoutKind.Horizontal);
		confirmDelete(application);
		require(!FileSystem.exists(cleanPath) && !clean.dirty && !root.node.containsDocument(clean)
			&& !application.documents.documents.contains(clean) && prompts == 0,
			"clean deletion retained split tabs, fabricated edits, or prompted to save");

		var dirtyPath = directory + "/dirty.hx";
		File.saveContent(dirtyPath, "class Dirty {}\n");
		application.open(dirtyPath);
		var dirty = application.documents.documents[0];
		var syntax = dirty.syntax;
		dirty.insert(new BufferSelection(), "// edits\n");
		var text = dirty.buffer.text;
		confirmDelete(application);
		require(!FileSystem.exists(dirtyPath) && dirty.path == null && dirty.dirty
			&& dirty.buffer.text == text && dirty.syntax == syntax && root.node.containsDocument(dirty),
			"dirty deletion lost buffer, syntax, or open view");
		require(application.recovery.load().filter(snapshot -> snapshot.id == dirty.recoveryId && snapshot.path == null && snapshot.text == text).length == 1,
			"deleted edits did not retain pathless recovery");
		application.files.requestCloseActiveTab();
		require(prompts == 1 && root.node.containsDocument(dirty), "Cancel did not preserve deleted edits");
		answer = "save";
		application.files.chooseSaveDestination = function(_, choose) choose(null, false);
		application.files.requestCloseActiveTab();
		require(prompts == 2 && root.node.containsDocument(dirty) && !FileSystem.exists(dirtyPath),
			"Save As cancellation closed edits or recreated deleted file");
		var savedPath = directory + "/saved.hx";
		if (FileSystem.exists(savedPath)) FileSystem.deleteFile(savedPath);
		application.files.chooseSaveDestination = function(_, choose) choose(savedPath, false);
		application.files.requestCloseActiveTab();
		require(prompts == 3 && File.getContent(savedPath) == text && !FileSystem.exists(dirtyPath)
			&& !root.node.containsDocument(dirty), "deleted edits did not save to the chosen destination");

		var externalPath = directory + "/external.hx";
		File.saveContent(externalPath, "class External {}\n");
		application.open(externalPath);
		var external = application.documents.documents[0];
		FileSystem.deleteFile(externalPath);
		require(external.checkExternal() == Deleted && external.path == externalPath && !external.dirty
			&& external.title == "external.hx (Deleted)" && root.node.containsDocument(external),
			"external deletion changed edit state or lost its missing-file indication");
		confirmDelete(application);
		require(root.node.containsDocument(external) && external.path == externalPath && !external.dirty,
			"failed deletion closed an editor or detached its identity");
		application.files.requestCloseActiveTab();
		require(prompts == 3 && !root.node.containsDocument(external), "clean external deletion prompted on close");

		File.saveContent(dirtyPath, "class Discard {}\n");
		application.open(dirtyPath);
		var discarded = application.documents.documents[0];
		discarded.insert(new BufferSelection(), "// edits\n");
		confirmDelete(application);
		answer = "discard";
		application.files.requestCloseActiveTab();
		require(prompts == 4 && !application.documents.documents.contains(discarded)
			&& application.recovery.load().filter(snapshot -> snapshot.id == discarded.recoveryId).length == 0,
			"discard retained deleted edits or their recovery snapshot");
		var folder = directory + "/mixed";
		FileSystem.createDirectory(folder);
		File.saveContent(folder + "/clean.hx", "class Clean {}\n");
		File.saveContent(folder + "/edited.hx", "class Edited {}\n");
		application.open(folder + "/clean.hx");
		var folderClean = application.documents.documents[0];
		application.open(folder + "/edited.hx");
		var folderDirty = application.documents.documents[1];
		folderDirty.insert(new BufferSelection(), "// keep\n");
		var project = application.workspace.addProject(directory);
		for (_ in 0...1000) {
			if (!project.indexing()) break;
			application.workspace.jobs.update(32);
		}
		require(root.sidebar.selectPath(folder), "folder deletion fixture did not appear in the tree");
		confirmDelete(application);
		require(!FileSystem.exists(folder) && !root.node.containsDocument(folderClean)
			&& !application.documents.documents.contains(folderClean) && !folderClean.dirty
			&& root.node.containsDocument(folderDirty) && folderDirty.dirty && folderDirty.path == null,
			"directory deletion did not separately reconcile clean and edited descendants");
		application.files.requestCloseActiveTab();
		require(prompts == 5 && !root.node.containsDocument(folderDirty), "edited folder descendant did not close through Discard");
		trace("PASS: clean split-tab deletion, dirty preservation, recovery, Cancel/Save As/Discard, external deletion, and mixed directory deletion");
	}
}
