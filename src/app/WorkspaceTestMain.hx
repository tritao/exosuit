package app;

import core.Application;
import platform.Native;
import platform.Platform;
import renderer.Renderer;
import session.WorkspaceSession;
import view.LayoutKind;
import editor.BufferSelection;
import jobs.JobTask;
import jobs.JobScheduler;
import search.ReplacementBackupStore;
import search.WorkspaceReplacement;
import workspace.FileOperations;
import workspace.TrashService;
import recovery.RecoveryStore;
import view.RootView;

private class CountingJob implements JobTask {
	public var steps:Int = 0;
	public var cancelled:Bool = false;
	final target:Int;

	public function new(target:Int) this.target = target;
	public function step():Bool {
		steps++;
		return steps >= target;
	}
	public function cancel():Void cancelled = true;
}

class WorkspaceTestMain {
	static function require(condition:Bool, message:String):Void {
		if (!condition) throw message;
	}

	static function finishSearch(application:Application):Void {
		var turns = 0;
		while (!application.workspaceSearch.complete && turns < 1000) {
			application.workspace.jobs.update(32);
			turns++;
		}
		require(application.workspaceSearch.complete, "workspace search did not complete within its bounded test turns");
	}

	static function main():Int {
		var arguments = Sys.args();
		require(arguments.length == 2, "expected project roots");
		Platform.startHeadless();
		var window = Native.window_create("workspace-test", 640, 320), renderer = new Renderer(window, "ignored-headlessly.ttf", 15),
			application = new Application((theme, focus, workspace, settings) -> new RootView(renderer, theme, focus, workspace, 640, 320, settings)),
			root:RootView = cast application.root,
			project = application.workspace.addProject(arguments[0], [".cache"]),
			visible = project.visibleNodes();
		var scheduler = new JobScheduler(), firstJob = new CountingJob(3), firstHandle = scheduler.schedule(firstJob);
		require(scheduler.update(2) == 2 && firstJob.steps == 2 && scheduler.activeCount() == 1,
			"job scheduler exceeded its bounded update or retired work early");
		var replacementJob = new CountingJob(1), replacementHandle = scheduler.replace(firstHandle, replacementJob);
		require(firstJob.cancelled && replacementHandle.id == firstHandle.id && replacementHandle.generation == firstHandle.generation + 1
			&& !scheduler.cancel(firstHandle), "job generation did not reject a stale handle");
		require(scheduler.update(1) == 1 && replacementJob.steps == 1 && scheduler.activeCount() == 0,
			"replacement job did not complete and retire");
		require(application.workspace.activeProject == project && visible.length == 6, "project root did not scan or ignored entries leaked");
		require(visible[0] == project.tree && visible[1].name == "alpha.txt" && visible[2].name == "binary.dat"
			&& visible[3].name == "oversized.dat" && visible[4].name == "src" && visible[5].name == "unreadable.txt",
			"project tree ordering failed");
		project.restoreExpanded([arguments[0] + "/src"]);
		application.workspace.refreshProjects(32);
		require(project.visibleNodes().length == 7 && project.visibleNodes()[5].name == "Main.hx", "directory expansion failed");
		application.commands.perform("project:sidebar-next", application.context);
		application.commands.perform("project:sidebar-open", application.context);
		require(application.documents.documents.length == 1 && application.documents.documents[0].path == visible[1].path,
			"sidebar command did not open selected file");
		root.mouseDown(Platform.MOUSE_LEFT, 20, view.Sidebar.HEADER_HEIGHT + view.Sidebar.ROW_HEIGHT * 4 + 1);
		require(!visible[4].expanded && root.sidebar.selected == 4, "sidebar mouse did not select and collapse directory");
		require(application.keyPressed(Platform.KEY_P, Platform.MOD_CTRL) && root.commandView.active, "Ctrl+P did not open file command view");
		application.textInput("main");
		require(root.commandView.results.length == 1 && root.commandView.results[0].label == "src/Main.hx",
			"file command view fuzzy filtering failed");
		application.keyPressed(Platform.KEY_ENTER, 0);
		require(application.documents.documents.length == 2 && !root.commandView.active, "file command view did not accept selection");
		var secondProject = application.workspace.addProject(arguments[1]);
		root.tabs.activeView.textInput("needle ");
		require(application.keyPressed(Platform.KEY_F, Platform.MOD_CTRL), "Ctrl+F did not open document find");
		application.textInput("needle");
		require(application.documentMatches.length == 1 && root.tabs.activeView.hasSelection(),
			"document find did not select an unsaved match");
		application.keyPressed(Platform.KEY_ESCAPE, 0);
		application.textInput("changed");
		require(application.documentMatches.length == 0, "document find retained a stale match after editing");
		root.tabs.activeView.undo();
		application.commands.perform("find:next", application.context);
		require(application.documentMatches.length == 1, "document find did not refresh after undo");
		require(application.replaceAll("found") == 1 && application.documents.documents[1].buffer.text.indexOf("needle") < 0,
			"replace all did not apply as one document operation");
		root.tabs.activeView.undo();
		require(application.documents.documents[1].buffer.text.indexOf("needle") >= 0, "one undo did not restore replace all");
		application.openDocumentFind();
		application.textInput("needle");
		application.keyPressed(Platform.KEY_ESCAPE, 0);
		require(root.tabs.activeView != null && root.tabs.activeView.searchMatchCount() == 0,
			"cancelled find retained transient highlights");
		root.tabs.switchBy(-1);
		application.commands.perform("find:next", application.context);
		require(application.documentMatches.length == 0, "document find results leaked across active documents");
		root.tabs.switchBy(1);
		require(application.keyPressed(Platform.KEY_F, Platform.MOD_CTRL + Platform.MOD_SHIFT), "Ctrl+Shift+F did not open workspace search");
		application.textInput("needle");
		application.workspaceSearch.flush();
		finishSearch(application);
		require(root.searchVisible && root.searchSidebar.results.length == 2,
			"workspace search did not include unsaved and multi-project matches: results="
			+ [for (match in application.workspaceSearch.results) match.path].join(",") + ", errors="
			+ application.workspaceSearch.errors.join(",") + ", complete=" + application.workspaceSearch.complete
			+ ", jobs=" + application.workspace.jobs.activeCount());
		require(application.workspaceSearch.complete && application.workspaceSearch.errors.length == 3
			&& application.workspaceSearch.results[0].document != null,
			"workspace search did not prefer dirty buffers or report skipped binary input");
		var staleGeneration = application.workspaceSearch.generation;
		application.workspaceSearch.request("never-present", application.searchOptions, 100);
		application.workspaceSearch.flush();
		application.workspace.jobs.update(1);
		application.workspaceSearch.request("needle", application.searchOptions, 1);
		application.workspaceSearch.flush();
		finishSearch(application);
		require(application.workspaceSearch.generation > staleGeneration && application.workspaceSearch.results.length == 1
			&& application.workspaceSearch.capped, "replacement search published stale results or ignored its cap");
		application.searchOptions.pathFilter = "second.txt";
		application.workspaceSearch.request("needle", application.searchOptions, 100);
		application.workspaceSearch.flush();
		finishSearch(application);
		require(application.workspaceSearch.results.length == 1
			&& StringTools.endsWith(application.workspaceSearch.results[0].path, "/second.txt"), "workspace path filtering failed");
		application.searchOptions.pathFilter = "";
		application.searchOptions.regularExpression = true;
		application.workspaceSearch.request("nee(dle)", application.searchOptions, 100);
		application.workspaceSearch.flush();
		finishSearch(application);
		require(application.workspaceSearch.results.length == 2 && application.workspaceSearch.results[0].captures[1] == "dle",
			"workspace regular-expression search did not preserve captures");
		application.workspaceSearch.request("(", application.searchOptions, 100);
		application.workspaceSearch.flush();
		require(application.workspaceSearch.complete && application.workspaceSearch.errors.length == 1,
			"invalid workspace regular expression did not become a visible error");
		application.searchOptions.regularExpression = false;
		application.workspaceSearch.request("needle", application.searchOptions, 100);
		application.workspaceSearch.flush();
		finishSearch(application);
		application.keyPressed(Platform.KEY_ENTER, 0);
		require(root.searchSidebar.active() != null, "workspace result activation failed");
		application.keyPressed(Platform.KEY_ESCAPE, 0);
		application.commands.perform("project:show-sidebar", application.context);
		require(!root.searchVisible, "workspace search could not return to the project sidebar");
		application.commands.perform("project:sidebar-next", application.context);
		require(application.keyPressed(Platform.KEY_P, Platform.MOD_CTRL + Platform.MOD_SHIFT), "Ctrl+Shift+P did not open command palette");
		application.textInput("sidebarprevious");
		require(root.commandView.results.length == 1, "command view fuzzy filtering failed");
		application.keyPressed(Platform.KEY_ENTER, 0);
		require(root.sidebar.selected == 0,
			"command palette did not dispatch selected command: selected=" + root.sidebar.selected);
		application.openFileCommandView();
		application.keyPressed(Platform.KEY_ESCAPE, 0);
		require(!root.commandView.active, "Escape did not cancel command view");
		require(application.commands.perform("workspace:replace", application.context), "workspace replacement command was unavailable");
		application.textInput("unused replacement");
		application.keyPressed(Platform.KEY_ENTER, 0);
		require(application.replacementPreview != null && root.commandView.active,
			"workspace replacement did not present an explicit preview confirmation");
		application.keyPressed(Platform.KEY_ESCAPE, 0);
		require(application.replacementPreview == null && !root.commandView.active,
			"cancelling replacement preview retained an applicable plan");
		var backupPath = arguments[0] + "-replacement-backup.conf", secondPath = arguments[1] + "/second.txt";
		if (application.workspace.fileSystem.exists(backupPath)) application.workspace.fileSystem.deleteFile(backupPath);
		var replacements = new WorkspaceReplacement(application.workspace,
			new ReplacementBackupStore(backupPath, application.workspace.fileSystem));
		var conflictPreview = replacements.preview(application.workspaceSearch, "swapped");
		require(application.workspace.fileSystem.writeAtomic(secondPath, "changed externally\n"), "could not create replacement conflict");
		var conflictResult = replacements.apply(conflictPreview);
		require(conflictResult.appliedFiles == 1 && conflictResult.conflicts == 1 && conflictResult.failures == 0
			&& application.documents.documents[1].buffer.text.indexOf("swapped") >= 0,
			"project replacement did not isolate a disk conflict from an open-document edit");
		require(application.documents.documents[1].buffer.undo(new BufferSelection())
			&& application.workspace.fileSystem.writeAtomic(secondPath, "needle in second project\n"),
			"could not restore replacement conflict fixture");
		application.workspaceSearch.request("needle", application.searchOptions, 100);
		application.workspaceSearch.flush();
		finishSearch(application);
		var applyPreview = replacements.preview(application.workspaceSearch, "swapped"), applyResult = replacements.apply(applyPreview),
			backedUp = new ReplacementBackupStore(backupPath, application.workspace.fileSystem).load();
		require(applyResult.appliedFiles == 2 && applyResult.appliedMatches == 2 && backedUp.length == 1
			&& backedUp[0].path == secondPath && backedUp[0].text == "needle in second project\n"
			&& backedUp[0].expectedCurrent == "swapped in second project\n" && backedUp[0].matchCount == 1
			&& application.workspace.fileSystem.read(secondPath) == "swapped in second project\n",
			"project replacement preview, atomic apply, outcomes, or backup failed");
		require(application.workspace.fileSystem.writeAtomic(secondPath, "changed after replacement\n")
			&& replacements.restoreLastBackup().conflicts == 1
			&& application.workspace.fileSystem.writeAtomic(secondPath, "swapped in second project\n"),
			"replacement backup restore did not protect a subsequently changed file");
		var restoreResult = replacements.restoreLastBackup();
		require(restoreResult.appliedFiles == 1 && restoreResult.appliedMatches == 1
			&& application.documents.documents[1].buffer.undo(new BufferSelection())
			&& application.workspace.fileSystem.read(secondPath) == "needle in second project\n",
			"could not restore successful replacement fixture");
		var createdPath = arguments[0] + "/created.txt", movedPath = arguments[0] + "/moved.txt";
		var fileOperations = new FileOperations(application.workspace,
			new TrashService(arguments[0] + "-trash", application.workspace.fileSystem));
		for (index in 0...16) application.workspace.refreshProjects(1);
		require(fileOperations.createFile(createdPath).success && !fileOperations.createFile(createdPath).success,
			"file creation or collision handling failed");
		for (index in 0...16) application.workspace.refreshProjects(1);
		require(project.files().length == 6,
			"incremental polling missed created file: generation=" + project.indexGeneration() + ", indexing=" + project.indexing()
			+ ", jobs=" + application.workspace.jobs.activeCount() + ", files=" + [for (file in project.files()) file.path].join(","));
		var movedDocument = application.documents.open(createdPath);
		movedDocument.insert(new BufferSelection(), "moved safely");
		require(fileOperations.move(createdPath, movedPath).success && movedDocument.path == movedPath,
			"rename did not reconcile dirty open document identity");
		require(!fileOperations.move(movedPath, arguments[0] + "/alpha.txt").success, "rename overwrote a collision");
		require(movedDocument.save() && !application.workspace.fileSystem.exists(createdPath)
			&& application.workspace.fileSystem.read(movedPath) == "moved safely", "renamed dirty document saved to its old path");
		movedDocument.insert(new BufferSelection(), "recoverable ");
		var removed = fileOperations.remove(movedPath);
		require(removed.success && removed.destination != null && application.workspace.fileSystem.exists(removed.destination)
			&& movedDocument.path == null && movedDocument.dirty && movedDocument.buffer.text == "recoverable moved safely",
			"recoverable deletion did not preserve a dirty open buffer and trash destination");
		application.documents.close(movedDocument, true);
		var createdFolder = arguments[0] + "/created-folder", movedFolder = arguments[0] + "/moved-folder",
			folderFile = createdFolder + "/nested.txt";
		require(fileOperations.createFolder(createdFolder).success && !fileOperations.createFolder(createdFolder).success
			&& fileOperations.createFile(folderFile).success, "folder creation or collision handling failed");
		var folderDocument = application.documents.open(folderFile);
		folderDocument.insert(new BufferSelection(), "nested");
		require(fileOperations.move(createdFolder, movedFolder).success && folderDocument.path == movedFolder + "/nested.txt"
			&& folderDocument.save() && !application.workspace.fileSystem.exists(folderFile),
			"directory move did not reconcile and safely save a nested open document");
		folderDocument.insert(new BufferSelection(), "dirty ");
		require(fileOperations.remove(movedFolder).success && folderDocument.path == null && folderDocument.dirty,
			"recoverable directory deletion lost its dirty nested document");
		application.documents.close(folderDocument, true);
		for (index in 0...16) application.workspace.refreshProjects(1);
		require(project.files().length == 5, "incremental polling retained deleted file");
		project.restoreExpanded([arguments[0] + "/src"]);
		root.splitActive(LayoutKind.Horizontal);
		application.open(arguments[1] + "/second.txt");
		var sessionRecovery = new RecoveryStore(arguments[0] + "-session-recovery.conf", application.workspace.fileSystem);
		require(sessionRecovery.save(application), "session recovery snapshot save failed");
		var session = WorkspaceSession.decode(WorkspaceSession.capture(application).encode());
		var expectedLayout = session.layout.copy();
		session.projects.push("/missing/session-project");
		session.layout.push("T\t1\t0\t0\t0\t0\t0\tP\t/missing/session-file");
		session.restore(application, sessionRecovery);
		require(root.sessionLines().join("\n") == expectedLayout.join("\n"), "layout tab order, active pane, cursor or scroll changed on restore");
		require(application.workspace.projects.length == 2 && !root.node.isLeaf()
			&& root.activeLeaf.tabs.activeView != null, "multi-root split session did not restore");
		require(project.visibleNodes().length == 7, "expanded project folders did not restore");
		require(application.workspace.removeProject(secondProject) && application.workspace.projects.length == 1,
			"closing a project did not retire its indexed state");
		require(application.commands.perform("build:run-task", application.context) && root.commandView.active,
			"deliberate build task command did not open the project task picker");
		application.keyPressed(Platform.KEY_ENTER, 0);
		var buildDeadline = Sys.time() + 5.0;
		while (application.build.active != null && Sys.time() < buildDeadline) application.update();
		require(application.build.active == null && application.build.output.lines.length == 3
			&& application.build.output.lines[1].diagnostic != null, "build task did not finish with a clickable diagnostic");
		root.mouseDown(Platform.MOUSE_LEFT, root.activeLeaf.x + 20,
			root.activeLeaf.y + editor.EditorView.HEADER_HEIGHT + renderer.lineHeight + 1);
		var buildView = root.tabs.activeView, buildDocument = buildView == null ? null : buildView.getDocument();
		require(buildView != null && buildDocument != null && buildDocument.path == arguments[0] + "/src/Main.hx"
			&& buildView.cursorLine() == 1 && buildView.cursorColumn() == 2,
			"clicking build output did not open the diagnostic file and position");
		renderer.begin();
		root.draw();
		renderer.present();
		var refreshDocument = application.documents.open(arguments[0] + "/alpha.txt");
		refreshDocument.buffer.replaceAllText("unique_sidebar_search\n", null);
		application.workspaceSearch.request("unique_sidebar_search", application.searchOptions, 100);
		application.search.update(Sys.time());
		application.workspaceSearch.flush(); finishSearch(application);
		require(application.workspaceSearch.results.length == 1 && application.workspaceSearch.results[0].line == 0,
			"search refresh fixture did not find dirty content");
		require(application.search.previewWorkspaceReplacement("replacement"), "search preview fixture failed");
		application.workspaceSearch.request("other query", application.searchOptions, 100);
		require(!application.search.applyWorkspaceReplacement() && refreshDocument.buffer.text == "unique_sidebar_search\n",
			"replacement applied a preview from another search generation");
		application.workspaceSearch.request("unique_sidebar_search", application.searchOptions, 100);
		application.workspaceSearch.flush(); finishSearch(application);
		require(application.search.previewWorkspaceReplacement("replacement"), "second search preview fixture failed");
		refreshDocument.buffer.replaceAllText("new line\nunique_sidebar_search\n", null);
		application.search.update(Sys.time());
		require(application.search.replacementPreview == null && !application.workspaceSearch.complete,
			"document edit did not invalidate preview and schedule fresh search");
		application.workspaceSearch.flush(); finishSearch(application);
		require(application.workspaceSearch.results.length == 1 && application.workspaceSearch.results[0].line == 1,
			"search refresh used stale line positions after edit");
		root.searchActivate();
		var refreshedView = root.activeLeaf.tabs.activeView;
		require(refreshedView != null && refreshedView.cursorLine() == 1,
			"refreshed result did not navigate to edited position");
		application.shutdown();
		renderer.destroy();
		Platform.require(Native.window_destroy(window), "destroy workspace test window");
		Native.shutdown();
		Sys.println("PASS: workspace projects, command view, and document/workspace search");
		return 0;
	}
}
