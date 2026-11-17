package ui;





import sys.io.File;
import haxeon.ui.core.UiEvent;
import haxeon.ui.core.View;
import haxeon.ui.core.TextStyleOverride;
import haxeon.ui.icons.IconName;
import haxeon.ui.widgets.text.Text;
import platform.HostCapability;
import feedback.NotificationKind;
import ui.UiDocumentView;
import workspace.PathKey;
import scm.ScmGroupId;
import scm.ScmSource;

/**
	The window's source control: the Source Control view and the Changes tab, the editor's and agent sessions' sources,
	gutter markers and decorations, and every stage, discard, commit and remote action they offer. ExosuitApp owns one.
**/
@:allow(ui)
class ScmPanelController {
	final app:ExosuitApp;

	public function new(app:ExosuitApp)
		this.app = app;

	/** The Source Control view's and Changes tab's source; in the Agents layout it narrows to the group's folder. */
	final panelScm = new LocalScmSourceCache();
	/** The editor's source while the panel's narrows (see editorSourceControlSource). */
	final editorScm = new LocalScmSourceCache();
	/** The sources behind Agent session controls, per session folder (see sessionSourceControlSource). */
	final sessionScm = new SessionScmSources();
	var sourceControlPanelValue:Null<SourceControlPanel>;
	var sourceControlPanelIdentity:Null<String>;
	final scmDecorationOwners:Map<String, Bool> = [];
	final scmDecorationRevisions:Map<String, String> = [];
	final scmDocumentMarkers:Map<Int, scm.ScmOpenDocumentMarkers> = [];
	final scmDocumentMarkerKeys:Map<Int, String> = [];
	final scmMarkerTargets:Map<Int, ScmMarkerTarget> = [];
	var scmBranchStatus:Null<plugin.PluginStatusItem>;
	var scmPresentationSourceIdentity:Null<String>;
	var pendingScmSource:Null<ScmSource>;
	var pendingScmRepository:Null<scm.ScmRepository>;
	var pendingScmGroup:Null<scm.ScmGroup>;
	var pendingScmResource:Null<scm.ScmResource>;
	var nextScmOperationId:Int = 1;
	var nextScmPoll:Float = 0.0;
	final scmAutoFetchPending:Map<String, Bool> = [];
	final scmAutoFetchLast:Map<String, Float> = [];
	/** The Source Control view's source: the active explorer root's, or in the Agents layout the group folder's. */
	public function sourceControlSource():Null<ScmSource> {
		if (app.workspaceAttachment != null && !app.workspaceAttachment.hasLocalFileAccess()) {
			clearLocalScmSource();
			return app.workspaceAttachment.sourceControlSource();
		}
		if (!app.capabilities.supports(HostCapability.SourceControl) || app.explorerRoot == null && app.contextScope() == null) {
			clearLocalScmSource();
			return null;
		}
		// A group's folder narrows to itself; the workspace's scope covers its folders whole.
		var scope = app.contextScope(), narrow = scope != null && !scope.isWorkspace();
		var roots = [for (root in app.contextRoots()) if (controller.SavedWorkspaceController.available(root)) root];
		if (roots.length == 0) { clearLocalScmSource(); return null; }
		return panelScm.get(app.application.scm, roots, narrow, function(_) {
			// A group folder may be any folder: outside the workspace, its own repository, or none. Discover each unless a
			// discovered root already covers it, which would only duplicate that root's polling.
			if (scope != null) for (root in roots)
				if (app.application.scm.repositories(root).length == 0) app.application.scm.discover(root, discovered);
		});
	}
	/**
		A frame once a discovery started for a new source has finished. One that fails at once (source control disabled, a
		folder that is gone) finishes inside the build that asked for the source: that build shows the result, and the
		frame tick may not be bumped from inside a build.
	**/
	function discovered(_:scm.ScmJobResult<Array<scm.ScmRepository>>):Void
		if (!haxeon.reactive.ReactiveRuntime.isTracking()) app.requestFrame();
	/**
		The source behind the editor's change markers and hunk actions. It never narrows to the Agents group's folder: a
		file opened from anywhere keeps its markers. While the Source Control source narrows, this one covers the active
		context's folders and the group's folder whole; otherwise it is the same source.
	**/
	function editorSourceControlSource():Null<ScmSource> {
		var panel = sourceControlSource(), scope = app.contextScope();
		if (scope == null || panel == null || panel.isRemote()) { editorScm.clear(); return panel; }
		var roots = [for (root in app.application.activeContext.roots) if (controller.SavedWorkspaceController.available(root)) root];
		for (folder in app.contextRoots())
			if (!Lambda.exists(roots, function(root) return PathKey.within(root, folder))) roots.push(folder);
		return editorScm.get(app.application.scm, roots, false);
	}
	/**
		The source behind an Agent session's branch, commit, worktree and GitHub controls. It never narrows to the Workbench
		selection: it covers the active context's folders and the session's folder `cwd`, so the controls describe the
		session's own folder whichever group is selected (see SessionScmSources). A workspace without local file access
		uses its own source.
	**/
	function sessionSourceControlSource(cwd:String):Null<ScmSource> {
		if (app.workspaceAttachment != null && !app.workspaceAttachment.hasLocalFileAccess()) {
			sessionScm.clear();
			return app.workspaceAttachment.sourceControlSource();
		}
		if (!app.capabilities.supports(HostCapability.SourceControl)) { sessionScm.clear(); return null; }
		var roots = [for (root in app.application.activeContext.roots) if (controller.SavedWorkspaceController.available(root)) root];
		var folder = app.normalizedPath(cwd);
		if (!controller.SavedWorkspaceController.available(folder)) folder = "";
		return sessionScm.get(app.application.scm, roots, folder, Sys.time(), function(_) {
			// A group folder may be any folder; discover it unless a discovered root already covers it.
			if (folder != "" && app.application.scm.repositories(folder).length == 0) app.application.scm.discover(folder, discovered);
		});
	}
	/** The session's source (see sessionSourceControlSource); null without a session record. */
	function sessionScmSource(resource:String, root:String):Null<ScmSource> {
		var record = app.agentTabs.sessionRecord(resource, root);
		return record == null ? null : sessionSourceControlSource(record.cwd);
	}
	/** Whether the session's files are on this machine (no remote attachment without local file access). */
	function sessionLocalFiles():Bool return app.workspaceAttachment == null || app.workspaceAttachment.hasLocalFileAccess();
	function syncScmSidebar():Void {
		var remoteRead = app.workspaceAttachment != null && !app.workspaceAttachment.hasLocalFileAccess()
			&& app.workspaceAttachment.sourceControlSource() != null;
		var enabled = app.capabilities.supports(HostCapability.SourceControl) || remoteRead;
		if (enabled && app.sidebar.find("scm") == null)
			app.registerSidebarDestination("scm", IconName.Hierarchy, sourceControlPanel,
				new haxeon.ui.widgets.sidebar.SidebarModeOptions("Source Control", 15, true));
		else if (!enabled && app.sidebar.find("scm") != null) {
			app.sidebar.unregister("scm");
			app.application.commands.remove("sidebar:scm");
			app.application.keymap.removeCommand("sidebar:scm");
		}
		if (enabled && app.application != null && !app.application.commands.contains("sidebar:scm")) {
			app.application.commands.add("sidebar:scm", function(_) { app.activateSidebarDestination("scm"); app.requestFrame(); });
			app.application.keymap.add(platform.Platform.KEY_G, platform.Platform.MOD_CTRL | platform.Platform.MOD_SHIFT, ["sidebar:scm"]);
		}
	}
	function sourceControlPanel():View {
		var source = sourceControlSource();
		if (source == null) {
			clearSourceControlPanel();
			return new Text(app.explorerRoot == null && app.contextScope() == null ? "Open a folder to view source control" : "Source control access is unavailable",
				null, app.theme.tokens.textSecondary, new TextStyleOverride(null, 13.0, null, haxeon.ui.TextWrap.WordCharacter));
		}
		// Compare the source itself: the local source cache replaces a disposed source with one of the same identity, and a
		// panel kept on the disposed one shows "disconnected" and "Loading repositories…" for good.
		if (sourceControlPanelValue == null || sourceControlPanelIdentity != source.identity() || !sourceControlPanelValue.shows(source)) {
			clearSourceControlPanel();
			sourceControlPanelIdentity = source.identity();
			sourceControlPanelValue = new SourceControlPanel(source, app.theme, function() {
				syncScmPresentation(source);
				app.requestFrame();
			}, function(repository, group, resource) {
				rememberScmResource(source, repository, group, resource);
				openScmResource(source, repository, group, resource);
				app.requestFrame();
			}, showScmResourceMenu,
				function() { source.discover(_ -> app.requestFrame()); }, trustScmRepository,
			function(repository, group, resource) {
				rememberScmResource(source, repository, group, resource);
				openScmSourceFile(source, repository, resource);
			}, function(repository, group, event) { showScmRepositoryMenu(source, repository, group, event); },
			function() return scmCommitRepository(source), function(repository) {
				var value = app.application.scmCommitDrafts.get(repository.id);
				return value == null ? "" : value;
			}, function(repository, value) {
				app.application.scmCommitDrafts.set(repository.id, value);
				app.requestFrame();
			}, function(repository, amend, all) {
				var value = app.application.scmCommitDrafts.get(repository.id);
				commitScmMessage(source, repository, value, amend, all);
			}, function(repository) return source.canWrite(repository.id) && hasStagedScmChanges(source, repository), function(repository, group, resource) {
				rememberScmResource(source, repository, group, resource);
			if (resource != null && group != null) applyPendingScmFile(group.id != ScmGroupId.Index);
			else applyPendingScmGroup(group == null || group.id != ScmGroupId.Index);
			}, function(repository, event) showScmCommitMenu(source, repository, event));
			syncScmPresentation(source);
		}
		return sourceControlPanelValue;
	}
	function clearSourceControlPanel():Void {
		if (sourceControlPanelValue != null) sourceControlPanelValue.dispose();
		sourceControlPanelValue = null;
		sourceControlPanelIdentity = null;
	}
	function clearScmPresentation():Void {
		app.scmBranches.cancel();
		for (owner in [for (value in scmDecorationOwners.keys()) value]) app.host.getResourceDecorations().removeOwner(owner);
		scmDecorationOwners.clear(); scmDecorationRevisions.clear();
		scmPresentationSourceIdentity = null;
		app.host.getPluginStatusItems().removeOwner("scm");
		scmBranchStatus = null;
	}
	/**
		Writes the source's explorer decorations and status bar items. The root build reads both registries' revisions
		before it builds, so a host frame is enough when they change; it may also run inside the build that creates the
		Source Control panel (see sourceControlPanel).
	**/
	function syncScmPresentation(source:ScmSource):Void {
		if (source == null) return;
		var decorationRegistry = app.host.getResourceDecorations();
		var statusRegistry = app.host.getPluginStatusItems();
		var decorationRevisionBefore = decorationRegistry.revision;
		var statusRevisionBefore = statusRegistry.revision;
		if (scmPresentationSourceIdentity != null && scmPresentationSourceIdentity != source.identity()) clearScmPresentation();
		scmPresentationSourceIdentity = source.identity();
		var desired:Map<String, Bool> = [];
		var repositories = source.repositories();
		for (repository in repositories) {
			var snapshot = source.snapshot(repository.id);
			if (snapshot == null) continue;
			var owner = "scm:" + source.identity() + ":" + repository.id;
			desired.set(owner, true);
			var revision = haxe.Int64.toStr(snapshot.revision);
			if (scmDecorationRevisions.get(owner) == revision) continue;
			app.host.getResourceDecorations().removeOwner(owner);
			for (group in snapshot.groups) {
			for (resource in group.resources) {
				var relative = resource.pathBytes.getString(0, resource.pathBytes.length);
				var path:String;
				if (source.isRemote()) {
					var scope = app.workspaceAttachment == null ? null : app.servedFolders.primaryScope(app.workspaceAttachment);
					var repoRelative = scope == null ? null : pathUnderScope(scope, repository.root);
					if (repoRelative == null) continue;
					path = repoRelative.length == 0 ? relative : repoRelative + "/" + relative;
				} else path = repository.root + "/" + relative;
				path = StringTools.replace(path, "\\", "/");
				var badge = scmStatusBadge(resource);
				var color = resource.conflictKind != null || resource.changeKind == scm.ScmChangeKind.Unmerged
					? plugin.PluginResourceDecorationColor.Danger
					: resource.changeKind == scm.ScmChangeKind.Added || resource.changeKind == scm.ScmChangeKind.Untracked
						? plugin.PluginResourceDecorationColor.Success
						: resource.changeKind == scm.ScmChangeKind.Deleted ? plugin.PluginResourceDecorationColor.Danger
						: resource.changeKind == scm.ScmChangeKind.Ignored ? plugin.PluginResourceDecorationColor.Secondary
						: plugin.PluginResourceDecorationColor.Warning;
				var priority = group.id == ScmGroupId.Merge ? 400 : group.id == ScmGroupId.Index ? 300 :
					group.id == ScmGroupId.WorkingTree ? 200 : group.id == ScmGroupId.Untracked ? 100 : 0;
				app.host.getResourceDecorations().add(owner, "resource:" + group.id + ":" + resource.pathBytes.length + ":" + resource.path,
					path, badge, color, "Source control · " + scmGroupLabel(group.id) + " · " + resource.path, true, priority);
			}
			}
			scmDecorationOwners.set(owner, true);
			scmDecorationRevisions.set(owner, revision);
		}
		for (owner in [for (owner in scmDecorationOwners.keys()) if (!desired.exists(owner)) owner]) {
			app.host.getResourceDecorations().removeOwner(owner);
			scmDecorationOwners.remove(owner); scmDecorationRevisions.remove(owner);
		}
		if (repositories.length == 0) {
			statusRegistry.removeOwner("scm"); scmBranchStatus = null;
			if (decorationRegistry.revision != decorationRevisionBefore || statusRegistry.revision != statusRevisionBefore) app.scheduleFrame();
			return;
		}
		var activeRepository = repositories[0], snapshot = source.snapshot(activeRepository.id);
		if (snapshot == null) return;
		var head = snapshot.head;
		var branch = head.branch != null ? head.branch : head.detachedCommit == null ? "No branch" : "detached " + head.detachedCommit.substr(0, 8);
		var text = branch;
		var tooltip = activeRepository.root + "\n" + text + (head.upstream == null ? "" : "\nUpstream: " + head.upstream)
			+ (head.operation == null ? "" : "\n" + Std.string(head.operation));
		var branchCommand = "scm:branches";
		var registry = statusRegistry;
		if (scmBranchStatus == null || registry.find("scm", "branch") == null)
			scmBranchStatus = registry.add("scm", "branch", text, 100, plugin.PluginStatusSide.Left,
				null, tooltip, branchCommand);
		else registry.update(scmBranchStatus, text, 100, plugin.PluginStatusSide.Left, null, tooltip, branchCommand);
		for (direction in ["ahead", "behind"]) {
			var count = direction == "ahead" ? head.ahead : head.behind;
			var id = "branch-" + direction;
			var item = registry.find("scm", id);
			if (count <= 0) {
				if (item != null) registry.remove(item);
				continue;
			}
			var icon = direction == "ahead" ? IconName.ArrowUp : IconName.ArrowDown;
			var priority = direction == "ahead" ? 99 : 98;
			var description = count + (count == 1 ? " commit " : " commits ") + direction
				+ (head.upstream == null ? "" : (direction == "ahead" ? " of " : " ") + head.upstream);
			if (item == null) registry.add("scm", id, Std.string(count), priority, plugin.PluginStatusSide.Left,
				icon, description, branchCommand);
			else registry.update(item, Std.string(count), priority, plugin.PluginStatusSide.Left,
				icon, description, branchCommand);
		}
		if (decorationRegistry.revision != decorationRevisionBefore || statusRegistry.revision != statusRevisionBefore) app.scheduleFrame();
	}
	function syncScmDocumentMarkers(now:Float):Void {
		var source = editorSourceControlSource();
		var desired:Map<Int, Bool> = [];
		var visited:Map<Int, Bool> = [];
		if (source != null && !source.isRemote()) {
			var repositories = source.repositories();
			var sourceIdentity = source.identity();
			for (view in app.host.allViews()) {
				var document = view.document;
				if (view.diffDocument != null || document.path == null) continue;
				visited.set(document.id, true);
				var target = scmMarkerTarget(sourceIdentity, repositories, document);
				if (target == null) continue;
				var repository = target.repository;
				var relative = target.relative;
				if (repository == null || relative == null) continue;
				var snapshot = source.snapshot(repository.id);
				if (snapshot == null) continue;
				// The group scan costs as much as the change list is long, so redo it only for a new snapshot.
				var scanned = target.snapshot;
				if (scanned != snapshot) {
					var untracked = false, worktree = false;
					for (group in snapshot.groups) for (resource in group.resources) if (resource.path == relative) {
						if (group.id == ScmGroupId.Untracked) untracked = true;
						if (group.id == ScmGroupId.WorkingTree) worktree = true;
					}
					target.snapshot = snapshot;
					target.untracked = untracked;
					target.worktree = worktree;
				}
				var identity = target.identity;
				var untracked = target.untracked, worktree = target.worktree;
				var previousIdentity = scmDocumentMarkerKeys.get(document.id);
				var tracker = scmDocumentMarkers.get(document.id);
				if (tracker != null && previousIdentity != identity) {
					tracker.dispose();
					scmDocumentMarkers.remove(document.id);
					scmDocumentMarkerKeys.remove(document.id);
					tracker = null;
				}
				if (tracker == null) {
					var documentId = document.id;
					tracker = new scm.ScmOpenDocumentMarkers(source, repository.id, haxe.io.Bytes.ofString(relative), document,
						"scm-open:" + documentId, app.host.getPluginGutterMarkers(), app.application.workspace.jobs,
						app.application.settings.current.scmDiffSizeLimit, app.requestFrame);
					scmDocumentMarkers.set(document.id, tracker);
					scmDocumentMarkerKeys.set(document.id, identity);
				}
				tracker.update(snapshot, document.dirty || worktree || untracked, untracked, now);
				desired.set(document.id, true);
			}
		}
		for (id in [for (id in scmDocumentMarkers.keys()) if (!desired.exists(id)) id]) {
			var tracker = scmDocumentMarkers.get(id);
			if (tracker != null) tracker.dispose();
			scmDocumentMarkers.remove(id);
			scmDocumentMarkerKeys.remove(id);
		}
		for (id in [for (id in scmMarkerTargets.keys()) if (!visited.exists(id)) id]) scmMarkerTargets.remove(id);
	}
	/** Resolves a document to its repository, recomputing only when its path or the repository list changed. */
	function scmMarkerTarget(sourceIdentity:String, repositories:Array<scm.ScmRepository>, document:editor.Document):Null<ScmMarkerTarget> {
		var cached = scmMarkerTargets.get(document.id);
		if (cached != null && cached.path == document.path && cached.sourceIdentity == sourceIdentity
			&& sameScmRepositories(cached.repositories, repositories)) return cached.repository == null ? null : cached;
		var repository:Null<scm.ScmRepository> = null, relative:Null<String> = null;
		for (candidate in repositories) {
			var candidatePath = scmRelativePath(candidate.root, document.path);
			if (candidatePath != null && (repository == null || candidate.root.length > repository.root.length)) {
				repository = candidate;
				relative = candidatePath;
			}
		}
		if (relative == null || relative.length == 0) repository = null;
		var target:ScmMarkerTarget = {
			path: document.path, sourceIdentity: sourceIdentity, repositories: repositories, repository: repository,
			relative: relative, identity: repository == null ? "" : sourceIdentity + "|" + repository.id + "|" + relative,
			snapshot: null, untracked: false, worktree: false
		};
		scmMarkerTargets.set(document.id, target);
		return repository == null ? null : target;
	}
	static function sameScmRepositories(left:Array<scm.ScmRepository>, right:Array<scm.ScmRepository>):Bool {
		if (left.length != right.length) return false;
		for (index in 0...left.length)
			if (left[index] != right[index] && (left[index].id != right[index].id || left[index].root != right[index].root)) return false;
		return true;
	}
	function scmRelativePath(root:String, path:String):Null<String> return PathKey.relative(app.normalizedPath(root), app.normalizedPath(path));
	static function scmStatusBadge(resource:scm.ScmResource):String {
		if (resource.conflictKind != null) return "!";
		return resource.changeKind == scm.ScmChangeKind.Added || resource.changeKind == scm.ScmChangeKind.Untracked ? "A" :
			resource.changeKind == scm.ScmChangeKind.Modified ? "M" : resource.changeKind == scm.ScmChangeKind.Deleted ? "D" :
			resource.changeKind == scm.ScmChangeKind.Renamed ? "R" : resource.changeKind == scm.ScmChangeKind.Copied ? "C" :
			resource.changeKind == scm.ScmChangeKind.TypeChanged ? "T" : resource.changeKind == scm.ScmChangeKind.Unmerged ? "!" :
			resource.changeKind == scm.ScmChangeKind.Ignored ? "I" : "?";
	}
	static function scmGroupLabel(group:ScmGroupId):String
		return group == ScmGroupId.Merge ? "Merge Changes" : group == ScmGroupId.Index ? "Staged Changes" :
			group == ScmGroupId.WorkingTree ? "Changes" : group == ScmGroupId.Untracked ? "Untracked" : Std.string(group);
	function trustScmRepository(repository:scm.ScmRepository):Void {
		var source = sourceControlSource();
		if (source == null || source.isRemote()) {
			app.application.reportError("source-control", "Trust this repository on the machine that runs Git");
			return;
		}
		source.trust(repository.id, function(result) {
			if (result.error != null || result.value != true)
				app.application.reportError("source-control", result.error == null ? "Could not trust repository" : result.error.message);
			else {
				source.refreshNow(repository.id);
				app.requestFrame();
			}
		});
	}
	function openScmResource(source:ScmSource, repository:scm.ScmRepository, group:scm.ScmGroup, resource:scm.ScmResource,
		sideBySide:Bool = false):Void {
		if (source == null || repository == null || group == null || resource == null) return;
		var relative = resource.pathBytes.getString(0, resource.pathBytes.length);
		if (group.id == ScmGroupId.Merge) {
			openScmWorktreeFile(source, repository, relative, function(path, contents, live) {
				if (source.isRemote()) openRemoteScmFile(repository, relative, -1);
				else if (path != null) app.application.open(path);
				app.closePhoneSidebarAfterOpen();
			});
			return;
		}
		var absolute = source.isRemote() ? null : repository.root + "/" + relative;
		var live = absolute == null ? null : app.findDocument(absolute);
		var snapshot = source.snapshot(repository.id);
		var revision = snapshot == null ? "" : haxe.Int64.toStr(snapshot.revision);
		var baseRef:scm.ScmRef = group.id == ScmGroupId.Index ? scm.ScmRef.Head : scm.ScmRef.Index;
		var refLabel = group.id == ScmGroupId.Index ? "HEAD→INDEX" : group.id == ScmGroupId.Untracked ? "EMPTY→WORKTREE" : "INDEX→WORKTREE";
		var open = function(oldText:String, newText:String):Void {
			var diffPath = absolute == null ? relative : absolute;
			if (sideBySide && !app.phoneLayoutActive) app.host.openScmSideBySide(repository.id, diffPath, refLabel, revision, oldText, newText, live);
			else app.host.openScmDiff(repository.id, diffPath, refLabel, revision, oldText, newText, live);
			app.closePhoneSidebarAfterOpen();
		};
		var loadCurrent = function(complete:String->Void):Void {
			if (group.id == ScmGroupId.Untracked) {
				openScmWorktreeFile(source, repository, relative, function(path, contents, _) {
					if (contents == null) reportScmReadError("Could not read untracked file " + resource.path);
					else open("", contents);
				});
				return;
			}
			if (group.id == ScmGroupId.Index) {
				readScmOriginal(source, repository.id, scm.ScmRef.Index, resource.pathBytes, function(contents, error) {
					if (error != null && error.code != "not_found" && error.code != "missing") reportScmReadError(error.message);
					else if (contents == null) open("", "");
					else open("", contents);
				});
				return;
			}
			openScmWorktreeFile(source, repository, relative, function(path, contents, live) {
				if (contents == null) reportScmReadError("Could not read changed file " + resource.path);
				else complete(contents);
			});
		};
		if (group.id == ScmGroupId.Index) {
			readScmOriginal(source, repository.id, baseRef, resource.pathBytes, function(base, error) {
				if (error != null && error.code != "not_found" && error.code != "missing") { reportScmReadError(error.message); return; }
				readScmOriginal(source, repository.id, scm.ScmRef.Index, resource.pathBytes, function(indexText, indexError) {
					if (indexError != null && indexError.code != "not_found" && indexError.code != "missing") { reportScmReadError(indexError.message); return; }
					open(base == null ? "" : base, indexText == null ? "" : indexText);
				});
			});
			return;
		}
		if (group.id == ScmGroupId.Untracked) { loadCurrent(function(_) {}); return; }
		readScmOriginal(source, repository.id, baseRef, resource.pathBytes, function(base, error) {
			if (error != null && error.code != "not_found" && error.code != "missing") { reportScmReadError(error.message); return; }
			loadCurrent(function(current) open(base == null ? "" : base, live != null ? live.buffer.text : current));
		});
	}
	function readScmOriginal(source:ScmSource, repositoryId:String, reference:scm.ScmRef, path:haxe.io.Bytes,
		complete:Null<String>->Null<scm.ScmError>->Void):Void {
		// A remote source answers over the workspace connection, whose events do not redraw the window.
		source.originalBytes(repositoryId, reference, path, function(result) {
			if (result.error != null || result.value == null) complete(null, result.error);
			else if (result.value.binary) complete(null, new scm.ScmError("binary", "Binary files cannot be shown as text diffs"));
			else complete(result.value.bytes.toString(), null);
			app.requestFrame();
		});
	}
	function openScmWorktreeFile(source:ScmSource, repository:scm.ScmRepository, relative:String,
		complete:Null<String>->Null<String>->Null<editor.Document>->Void):Void {
		if (source.isRemote()) {
			var attachment = app.workspaceAttachment, client = attachment == null ? null : attachment.fileClient();
			var scope = attachment == null ? null : app.servedFolders.primaryScope(attachment);
			if (attachment == null || client == null || scope == null) { complete(null, null, null); return; }
			var repoRelative = pathUnderScope(scope, repository.root);
			if (repoRelative == null) { complete(null, null, null); return; }
			var path = repoRelative.length == 0 ? relative : repoRelative + "/" + relative;
			// The result arrives over the workspace connection, whose events do not redraw the window.
			WorkspaceFileReader.read(client, attachment.fileWorkspace(), "root", path, null, function(result) {
				complete(null, result.error == null ? result.contents : null, null);
				app.requestFrame();
			});
			return;
		}
		var path = repository.root + "/" + relative;
		var live = app.findDocument(path);
		if (live != null && live.dirty) { complete(path, live.buffer.text, live); return; }
		if (!app.application.workspace.fileSystem.exists(path)) { complete(path, "", live); return; }
		try complete(path, app.application.workspace.fileSystem.read(path), live)
		catch (_:Dynamic) complete(path, null, live);
	}
	function openRemoteScmFile(repository:scm.ScmRepository, relative:String, line:Int):Void {
		var attachment = app.workspaceAttachment, client = attachment == null ? null : attachment.fileClient();
		var scope = attachment == null ? null : app.servedFolders.primaryScope(attachment);
		if (attachment == null || client == null || scope == null) { reportScmReadError("Workspace file service is unavailable"); return; }
		var repoRelative = pathUnderScope(scope, repository.root);
		if (repoRelative == null) { reportScmReadError("Repository is outside the workspace file root"); return; }
		var path = repoRelative.length == 0 ? relative : repoRelative + "/" + relative;
		var workspaceId = attachment.fileWorkspace();
		client.stat(workspaceId, "root", path, function(stat) {
			if (app.workspaceAttachment != attachment || stat == null || stat.entry == null || stat.entry.kind != "file") {
				reportScmReadError("The changed file is no longer available");
				app.requestFrame();
				return;
			}
			var rootName = scope;
			var slash = rootName.lastIndexOf("/");
			if (slash >= 0) rootName = rootName.substring(slash + 1);
			app.remoteFileTabs.openWorkspaceFileSnapshot(attachment, workspaceId, scope, "root", rootName, path, stat.entry.revision,
				WorkspaceFileReader.previewSize(stat.entry.size), false, null);
			if (line >= 0) {
				var existing = app.host.workspaceFile(scope, "root", path);
				if (existing != null) existing.selectSearchMatch(line, 0, 0);
			}
			app.requestFrame();
		}, function(error) {
			reportScmReadError(error == null ? "Could not open changed workspace file" : error.message);
			app.requestFrame();
		});
	}
	static function pathUnderScope(scope:String, root:String):Null<String> {
		var base = StringTools.replace(scope, "\\", "/"), full = StringTools.replace(root, "\\", "/");
		while (StringTools.endsWith(base, "/")) base = base.substr(0, base.length - 1);
		if (full == base) return "";
		var prefix = base + "/";
		if (!StringTools.startsWith(full, prefix)) return null;
		return full.substr(prefix.length);
	}
	function reportScmReadError(message:String):Void app.application.reportError("source-control", message);
	function rememberScmResource(source:Null<ScmSource>, repository:scm.ScmRepository, group:Null<scm.ScmGroup>,
		resource:Null<scm.ScmResource>):Void {
		pendingScmSource = source;
		pendingScmRepository = repository;
		pendingScmGroup = group;
		pendingScmResource = resource;
	}
	function showScmResourceMenu(repository:scm.ScmRepository, group:scm.ScmGroup, resource:scm.ScmResource, event:UiEvent):Void {
		rememberScmResource(sourceControlSource(), repository, group, resource);
		var entries = [
			new CommandMenuEntry("scm:open-changes", "Open Changes"),
			new CommandMenuEntry("scm:open-file", "Open File")
		];
		if (group.id != ScmGroupId.Merge)
			entries.push(new CommandMenuEntry("scm:open-side-by-side", "Compare Side by Side"));
		if (group.id == ScmGroupId.Merge && canResolvePendingScmConflict()) {
			entries.push(new CommandMenuEntry("scm:resolve-ours", "Accept Ours"));
			entries.push(new CommandMenuEntry("scm:resolve-theirs", "Accept Theirs"));
			entries.push(new CommandMenuEntry("scm:resolve-both", "Accept Both"));
		}
		if (canStagePendingScmFile()) entries.push(new CommandMenuEntry("scm:stage", group.id == ScmGroupId.Merge ? "Mark Resolved (Stage)" : "Stage File"));
		if (canUnstagePendingScmFile()) entries.push(new CommandMenuEntry("scm:unstage", "Unstage File"));
		if (canDiscardPendingScmFile()) entries.push(new CommandMenuEntry("scm:discard", "Discard Changes"));
		app.showContextMenu(entries, event, function() return true);
	}
	function showScmRepositoryMenu(source:ScmSource, repository:scm.ScmRepository, group:Null<scm.ScmGroup>, event:UiEvent):Void {
		rememberScmResource(source, repository, group, null);
		var entries:Array<CommandMenuEntry> = [];
		if (group == null && canCheckoutScmRepository(repository)) {
			entries.push(new CommandMenuEntry("scm:checkout-selected", "Switch Branch…"));
			entries.push(new CommandMenuEntry("scm:create-branch-selected", "Create Branch…"));
		}
		if (canStagePendingScmGroup()) entries.push(new CommandMenuEntry("scm:stage-all", group == null ? "Stage All Changes" : "Stage Group"));
		if (canUnstagePendingScmGroup()) entries.push(new CommandMenuEntry("scm:unstage-all", group == null ? "Unstage All Changes" : "Unstage Group"));
		if (group == null && source.canUseRemotes(repository.id)) {
			entries.push(new CommandMenuEntry("scm:fetch", "Fetch Remotes"));
			entries.push(new CommandMenuEntry("scm:pull", "Pull (Fast Forward Only)"));
			entries.push(new CommandMenuEntry("scm:push", "Push"));
		}
		if (entries.length == 0) return;
		app.showContextMenu(entries, event, function() return true);
	}
	/** Whether branches can be switched in `repository` (the first one when null) through `through`, or the panel's source. */
	function canCheckoutScmRepository(repository:Null<scm.ScmRepository>, ?through:ScmSource):Bool {
		var source = through != null ? through : sourceControlSource();
		if (source == null) return false;
		var target = repository;
		if (target == null) {
			var repositories = source.repositories();
			target = repositories.length == 0 ? null : repositories[0];
		}
		if (target == null || !source.canWrite(target.id)) return false;
		var features = source.features(target.id);
		return features != null && features.branches;
	}
	function isScmSourceActive(identity:String):Bool {
		var source = sourceControlSource();
		return source != null && source.identity() == identity;
	}
	function canUsePendingScmRemotes():Bool {
		var source = pendingScmSource, repository = pendingScmRepository;
		if (source == null || repository == null || !source.canUseRemotes(repository.id)) return false;
		var features = source.features(repository.id);
		return features != null && features.remotes;
	}
	function applyPendingScmRemote(operation:scm.ScmOperation):Void {
		if (!canUsePendingScmRemotes()) return;
		var source = pendingScmSource, repository = pendingScmRepository;
		if (source == null || repository == null) return;
		var snapshot = source.snapshot(repository.id);
		if (snapshot == null) {
			app.application.reportError("source-control", "Refresh the repository before running a Git remote operation");
			return;
		}
		function start():Void {
			var label = switch operation {
				case Fetch(_): "Fetch";
				case Pull: "Pull";
				case Push: "Push";
				case _: "Git remote operation";
			};
			app.host.getNotifications().publish(label + " in progress…", feedback.NotificationKind.Information, "source-control");
			var operationId = "ui-" + Std.string(nextScmOperationId++);
			switch operation {
				case Fetch(_): scmAutoFetchLast.set(source.identity() + "\n" + repository.id, Sys.time());
				case _:
			}
			source.apply(repository.id, operationId, snapshot.revision, operation, function(result) {
				if (result.error != null) {
					app.host.getNotifications().publish(label + " failed: " + result.error.message,
						feedback.NotificationKind.Error, "source-control");
					app.application.reportError("source-control", result.error.message);
				} else {
					app.host.getNotifications().publish(label + " completed", feedback.NotificationKind.Information, "source-control");
					source.refreshNow(repository.id);
				}
				app.requestFrame();
			});
		}
		var isInitialPush = switch operation {
			case Push: snapshot.head.upstream == null;
			case _: false;
		};
		if (isInitialPush) {
			app.application.confirmations.choose('Push the current branch to origin and set its upstream?', ["push", "cancel"], function(answer) {
				if (answer == "push") start();
			});
		} else start();
	}
	function maybeAutoFetchScm(source:ScmSource, now:Float):Void {
		if (!app.application.settings.current.scmAutoFetch || !source.connected()) return;
		for (repository in source.repositories()) {
			if (!source.canUseRemotes(repository.id)) continue;
			var features = source.features(repository.id);
			if (features == null || !features.remotes) continue;
			var key = source.identity() + "\n" + repository.id;
			if (scmAutoFetchPending.exists(key)) continue;
			var last = scmAutoFetchLast.get(key);
			if (last == null) { scmAutoFetchLast.set(key, now); continue; }
			if (now - last < 300.0) continue;
			var snapshot = source.snapshot(repository.id);
			if (snapshot == null) continue;
			scmAutoFetchLast.set(key, now);
			scmAutoFetchPending.set(key, true);
			var operationId = "auto-fetch-" + Std.string(nextScmOperationId++);
			source.apply(repository.id, operationId, snapshot.revision, scm.ScmOperation.Fetch(null), function(result) {
				scmAutoFetchPending.remove(key);
				if (result.error != null) {
					app.host.getNotifications().publish("Automatic fetch failed: " + result.error.message,
						feedback.NotificationKind.Warning, "source-control");
					app.application.reportError("source-control", result.error.message);
				} else source.refreshNow(repository.id);
				app.requestFrame();
			});
		}
	}
	function canStagePendingScmFile():Bool {
		var source = pendingScmSource, repository = pendingScmRepository, group = pendingScmGroup, resource = pendingScmResource;
		return source != null && repository != null && group != null && resource != null && source.canWrite(repository.id)
			&& (group.id == ScmGroupId.WorkingTree || group.id == ScmGroupId.Untracked || group.id == ScmGroupId.Merge);
	}
	function canResolvePendingScmConflict():Bool {
		var source = pendingScmSource, repository = pendingScmRepository, group = pendingScmGroup, resource = pendingScmResource;
		if (source == null || repository == null || group == null || resource == null || group.id != ScmGroupId.Merge
			|| !source.canWrite(repository.id)) return false;
		var features = source.features(repository.id);
		return features != null && features.staging;
	}
	function applyPendingScmConflict(choice:String):Void {
		if (!canResolvePendingScmConflict()) return;
		var source = pendingScmSource, repository = pendingScmRepository, resource = pendingScmResource;
		if (source == null || repository == null || resource == null) return;
		var snapshot = source.snapshot(repository.id);
		if (snapshot == null) { app.application.reportError("source-control", "Refresh the repository before resolving conflicts"); return; }
		app.host.getNotifications().publish("Resolving conflict in " + resource.path + "…", feedback.NotificationKind.Information, "source-control");
		var operationId = "ui-" + Std.string(nextScmOperationId++);
		source.apply(repository.id, operationId, snapshot.revision, scm.ScmOperation.ResolveConflict(resource.path, choice), function(result) {
			if (result.error != null) {
				app.host.getNotifications().publish("Conflict resolution failed: " + result.error.message,
					feedback.NotificationKind.Error, "source-control");
				app.application.reportError("source-control", result.error.message);
			} else {
				app.host.getNotifications().publish("Resolved " + resource.path + " using " + choice,
					feedback.NotificationKind.Information, "source-control");
				source.refreshNow(repository.id);
			}
			app.requestFrame();
		});
	}
	function canTrustPendingScmRepository():Bool {
		var source = pendingScmSource, repository = pendingScmRepository;
		return source != null && repository != null && !source.isRemote() && !repository.trusted;
	}
	function refreshSourceControl():Void {
		var source = sourceControlSource();
		if (source == null) return;
		source.poll();
		for (repository in source.repositories()) source.refreshNow(repository.id);
		source.discover(function(result) {
			if (result.error != null) app.application.reportError("source-control", result.error.message);
			else for (repository in result.value) source.refreshNow(repository.id);
			source.poll();
			syncScmPresentation(source);
			app.requestFrame();
		});
	}
	function canUnstagePendingScmFile():Bool {
		var source = pendingScmSource, repository = pendingScmRepository, group = pendingScmGroup, resource = pendingScmResource;
		return source != null && repository != null && group != null && resource != null && source.canWrite(repository.id)
			&& group.id == ScmGroupId.Index;
	}
	function canDiscardPendingScmFile():Bool {
		var source = pendingScmSource, repository = pendingScmRepository, group = pendingScmGroup, resource = pendingScmResource;
		return source != null && repository != null && group != null && resource != null && source.canWrite(repository.id)
			&& (group.id == ScmGroupId.WorkingTree || group.id == ScmGroupId.Untracked);
	}
	function discardPendingScmFile():Void {
		if (!canDiscardPendingScmFile()) return;
		var source = pendingScmSource, repository = pendingScmRepository, group = pendingScmGroup, resource = pendingScmResource;
		if (source == null || repository == null || group == null || resource == null) return;
		var snapshot = source.snapshot(repository.id);
		if (snapshot == null) { app.application.reportError("source-control", "Refresh the repository before discarding changes"); return; }
		var relative = resource.pathBytes.getString(0, resource.pathBytes.length);
		var path = repository.root + "/" + StringTools.replace(relative, "\\", "/");
		var dirty = [for (document in app.application.documents.documents)
			if (document.dirty && document.hasBackingPath() && PathKey.same(document.requirePath(), path)) document];
		function confirmDiscard(reloadBuffers:Bool):Void {
			app.application.confirmations.choose("Discard changes to 1 file?",
				["discard", "cancel"], function(answer) {
					if (answer != "discard") return;
					if (group.id == ScmGroupId.Untracked && !source.isRemote()) {
						var removed = app.application.fileOperations.remove(path);
						if (!removed.success) { app.application.reportError("source-control", removed.detail); return; }
						app.application.workspace.refreshProjects();
						source.refreshNow(repository.id);
						var trashPath = removed.destination;
						app.host.getNotifications().publish("Moved " + relative + " to recoverable trash", feedback.NotificationKind.Information,
							"source-control", [new feedback.NotificationAction("Undo", function() {
								if (trashPath == null || app.application.workspace.fileSystem.exists(path)
									|| !app.application.workspace.fileSystem.rename(trashPath, path)) {
								app.application.reportError("source-control", "Could not restore " + relative + " from trash");
								return;
							}
							app.application.workspace.refreshProjects();
							source.refreshNow(repository.id);
							app.requestFrame();
							})]);
						if (reloadBuffers) for (document in dirty) document.reloadFromDisk();
						app.requestFrame();
						return;
					}
					var operationId = "ui-" + Std.string(nextScmOperationId++);
					source.apply(repository.id, operationId, snapshot.revision, scm.ScmOperation.Discard(relative), function(result) {
						if (result.error != null) { app.application.reportError("source-control", result.error.message); return; }
						source.refreshNow(repository.id);
						if (reloadBuffers) for (document in dirty) document.reloadFromDisk();
						var token = result.value == null ? null : result.value.recoveryToken;
						if (token != null) app.host.getNotifications().publish("Discarded changes to " + relative,
							feedback.NotificationKind.Information, "source-control", [new feedback.NotificationAction("Undo", function() {
								var latest = source.snapshot(repository.id);
								if (latest == null) { app.application.reportError("source-control", "Refresh before undoing the discard"); return; }
								var undoId = "ui-" + Std.string(nextScmOperationId++);
								source.apply(repository.id, undoId, latest.revision, scm.ScmOperation.RestoreDiscard(relative, token), function(undo) {
									if (undo.error != null) app.application.reportError("source-control", undo.error.message);
									else source.refreshNow(repository.id);
									app.requestFrame();
								});
							})]);
						app.requestFrame();
					});
				});
		}
		if (dirty.length > 0) {
			app.application.confirmations.choose('An open buffer has unsaved edits. Choose reload after discard or keep the buffer: ',
				["reload", "keep", "cancel"], function(choice) {
					if (choice == "reload") confirmDiscard(true);
					else if (choice == "keep") confirmDiscard(false);
				});
		} else confirmDiscard(false);
	}
	function canStagePendingScmGroup():Bool {
		var source = pendingScmSource, repository = pendingScmRepository, group = pendingScmGroup;
		if (source == null || repository == null || !source.canWrite(repository.id)) return false;
		var snapshot = source.snapshot(repository.id);
		if (snapshot == null) return false;
		if (group == null) return hasScmResources(snapshot, [ScmGroupId.WorkingTree, ScmGroupId.Untracked]);
		return (group.id == ScmGroupId.WorkingTree || group.id == ScmGroupId.Untracked) && group.resources.length > 0;
	}
	function canUnstagePendingScmGroup():Bool {
		var source = pendingScmSource, repository = pendingScmRepository, group = pendingScmGroup;
		if (source == null || repository == null || !source.canWrite(repository.id)) return false;
		var snapshot = source.snapshot(repository.id);
		if (snapshot == null) return false;
		if (group == null) return hasScmResources(snapshot, [ScmGroupId.Index]);
		return group.id == ScmGroupId.Index && group.resources.length > 0;
	}
	static function hasScmResources(snapshot:scm.ScmSnapshot, ids:Array<ScmGroupId>):Bool {
		for (group in snapshot.groups) if (ids.indexOf(group.id) >= 0 && group.resources.length > 0) return true;
		return false;
	}
	function applyPendingScmGroup(stage:Bool):Void {
		var source = pendingScmSource, repository = pendingScmRepository, group = pendingScmGroup;
		if (source == null || repository == null || (stage ? !canStagePendingScmGroup() : !canUnstagePendingScmGroup())) return;
		var snapshot = source.snapshot(repository.id);
		if (snapshot == null) return;
		if (group == null) {
			var operation = stage ? scm.ScmOperation.StageAll : scm.ScmOperation.UnstageAll;
			applyScmOperation(source, repository, snapshot, operation);
			return;
		}
		var paths = [for (resource in group.resources) resource.pathBytes.getString(0, resource.pathBytes.length)];
		var operation = stage ? scm.ScmOperation.StagePaths(paths) : scm.ScmOperation.UnstagePaths(paths);
		applyScmOperation(source, repository, snapshot, operation);
	}
	function applyScmOperation(source:ScmSource, repository:scm.ScmRepository, snapshot:scm.ScmSnapshot,
		operation:scm.ScmOperation):Void {
		var operationId = "ui-" + Std.string(nextScmOperationId++);
		source.apply(repository.id, operationId, snapshot.revision, operation, function(result) {
			if (result.error != null) app.application.reportError("source-control", scmErrorText(result.error));
			source.refreshNow(repository.id);
			app.requestFrame();
		});
	}
	/** A Source Control error as the user reads it, with what to do when a folder-narrowed source refused it. */
	static function scmErrorText(error:scm.ScmError):String
		return error.code == scm.ScmFolderScope.OUTSIDE_FOLDER
			? error.message + " Unstage them, or commit from the Editor layout's Source Control."
			: error.code == scm.git.GitScopedCommit.OPERATION_IN_PROGRESS
			? error.message + " Finish or abort it from the Editor layout's Source Control." : error.message;
	function scmCommitRepository(source:ScmSource):Null<scm.ScmRepository> {
		if (source == null) return null;
		if (pendingScmSource != null && pendingScmSource.identity() == source.identity() && pendingScmRepository != null)
			return pendingScmRepository;
		var repositories = source.repositories();
		return repositories.length == 0 ? null : repositories[0];
	}
	function hasStagedScmChanges(source:ScmSource, repository:scm.ScmRepository):Bool {
		var snapshot = source.snapshot(repository.id);
		if (snapshot == null) return false;
		for (group in snapshot.groups)
			if (group.id == ScmGroupId.Index && group.resources.length > 0) return true;
		return false;
	}
	function canCommitStagedCurrentScmRepository():Bool {
		var source = sourceControlSource(), repository = source == null ? null : scmCommitRepository(source);
		return source != null && repository != null && source.canWrite(repository.id) && hasStagedScmChanges(source, repository)
			&& canCommitCurrentScmRepository();
	}
	function canAmendCurrentScmRepository():Bool {
		var source = sourceControlSource(), repository = source == null ? null : scmCommitRepository(source);
		if (source == null || repository == null || !source.canWrite(repository.id) || !canCommitCurrentScmRepository()) return false;
		var features = source.features(repository.id);
		return features != null && features.amend;
	}
	function canCommitAllCurrentScmRepository():Bool {
		var source = sourceControlSource(), repository = source == null ? null : scmCommitRepository(source);
		return app.application.settings.current.scmCommitAllWhenNothingStaged && source != null && repository != null
			&& source.canWrite(repository.id) && !hasStagedScmChanges(source, repository) && canCommitCurrentScmRepository();
	}
	function showScmCommitMenu(source:ScmSource, repository:scm.ScmRepository, event:UiEvent):Void {
		rememberScmResource(source, repository, null, null);
		var entries:Array<CommandMenuEntry> = [];
		if (hasStagedScmChanges(source, repository)) entries.push(new CommandMenuEntry("scm:commit", "Commit Staged"));
		var features = source.features(repository.id);
		if (features != null && features.amend) entries.push(new CommandMenuEntry("scm:commit-amend", "Amend Last Commit"));
		if (app.application.settings.current.scmCommitAllWhenNothingStaged && !hasStagedScmChanges(source, repository))
			entries.push(new CommandMenuEntry("scm:commit-all", "Commit All Changes"));
		if (entries.length == 0) return;
		app.showContextMenu(entries, event, function() return isScmSourceActive(source.identity()) && source.canWrite(repository.id));
	}
	function canCommitCurrentScmRepository():Bool {
		var source = sourceControlSource(), repository = source == null ? null : scmCommitRepository(source);
		if (source == null || repository == null || !source.canWrite(repository.id)) return false;
		var message = app.application.scmCommitDrafts.get(repository.id);
		return message != null && StringTools.trim(message).length > 0;
	}
	function commitScmMessage(source:ScmSource, repository:scm.ScmRepository, message:Null<String>, amend:Bool, all:Bool):Void {
		if (source == null || repository == null || !source.canWrite(repository.id)) return;
		var commitMessage = message == null ? "" : message;
		if (StringTools.trim(commitMessage).length == 0) return;
		if (amend) {
			var features = source.features(repository.id);
			if (features == null || !features.amend) return;
		}
		function beginCommit():Void {
			var snapshot = source.snapshot(repository.id);
			if (snapshot == null) { app.application.reportError("source-control", "Refresh the repository before committing"); return; }
			function commitWithSnapshot(expected:scm.ScmSnapshot):Void {
				var operationId = "ui-" + Std.string(nextScmOperationId++);
				source.apply(repository.id, operationId, expected.revision, scm.ScmOperation.Commit(commitMessage, amend), function(result) {
					if (result.error != null) {
						app.application.build.output.reset(repository.root);
						app.application.build.output.append("Git commit failed\n" + scmErrorText(result.error) + "\n");
						app.application.build.output.finish();
						app.host.showBuildOutput("Source Control Commit", app.application.build.output);
						app.application.reportError("source-control", scmErrorText(result.error));
						return;
					}
					app.application.scmCommitDrafts.set(repository.id, "");
					source.refreshNow(repository.id);
					app.host.getNotifications().publish(amend ? "Commit amended" : "Commit created",
						feedback.NotificationKind.Information, "source-control");
					app.requestFrame();
				});
			}
			if (!all) { commitWithSnapshot(snapshot); return; }
			var stageId = "ui-" + Std.string(nextScmOperationId++);
			source.apply(repository.id, stageId, snapshot.revision, scm.ScmOperation.StageAll, function(staged) {
				if (staged.error != null) { app.application.reportError("source-control", staged.error.message); return; }
				var refreshed = source.snapshot(repository.id);
				commitWithSnapshot(refreshed == null ? snapshot : refreshed);
			});
		}
		var dirtyDocuments = [for (document in app.application.documents.documents) if (document.dirty) document];
		if (dirtyDocuments.length == 0) { beginCommit(); return; }
		app.application.confirmations.choose('There are ' + dirtyDocuments.length + ' unsaved document(s). Save All before committing? ',
			["save-all", "commit-without-saving", "cancel"], function(answer) {
				if (answer == "save-all") app.application.files.saveAll(function(saved) {
					if (saved) beginCommit();
					else app.application.reportError("source-control", "Save All did not complete; commit cancelled");
				});
				else if (answer == "commit-without-saving") beginCommit();
			});
	}
	function applyPendingScmFile(stage:Bool):Void {
		var source = pendingScmSource, repository = pendingScmRepository, group = pendingScmGroup, resource = pendingScmResource;
		if (source == null || repository == null || group == null || resource == null
			|| (stage ? !canStagePendingScmFile() : !canUnstagePendingScmFile())) return;
		var snapshot = source.snapshot(repository.id);
		if (snapshot == null) { app.application.reportError("source-control", "Refresh the repository before changing its index"); return; }
		var path = resource.pathBytes.getString(0, resource.pathBytes.length);
		var operation = stage ? scm.ScmOperation.Stage(path) : scm.ScmOperation.Unstage(path);
		applyScmOperation(source, repository, snapshot, operation);
	}
	function openPendingScmFile():Void {
		var source = pendingScmSource;
		if (source == null) return;
		var repository = pendingScmRepository;
		if (repository == null) return;
		var resource = pendingScmResource;
		if (resource == null) return;
		openScmSourceFile(source, repository, resource);
	}
	function openScmSourceFile(source:ScmSource, repository:scm.ScmRepository, resource:scm.ScmResource):Void {
		if (source == null || repository == null || resource == null) return;
		var relative = resource.pathBytes.getString(0, resource.pathBytes.length);
		if (source.isRemote()) openRemoteScmFile(repository, relative, -1);
		else app.application.open(repository.root + "/" + relative);
		app.closePhoneSidebarAfterOpen();
	}
	function activeDiffView():Null<UiDocumentView> {
		var view = app.host.activeView();
		return view != null && view.diffDocument != null && !view.sideBySideDiff ? view : null;
	}
	function canApplyActiveScmHunk(action:String):Bool {
		var source = editorSourceControlSource(), view = app.host.activeView();
		if (source == null || view == null) return false;
		if (view.diffDocument != null) {
			if (view.sideBySideDiff) return false;
			var diff = view.diffDocument, repository = source.repository(diff.repositoryId);
			if (repository == null || !source.canWrite(repository.id)) return false;
			var features = source.features(repository.id), snapshot = source.snapshot(repository.id);
			if (features == null || !features.partialStaging || snapshot == null) return false;
			var staged = diff.reference == "HEAD→INDEX";
			if (action == "unstage" ? !staged : staged ||
				(diff.reference != "INDEX→WORKTREE" && diff.reference != "EMPTY→WORKTREE")) return false;
			var relative = source.isRemote() ? diff.path : pathUnderScope(repository.root, diff.path);
			var hunk = diff.hunkIndexAtLine(view.selection.cursor.line);
			return relative != null && hunk >= 0 && diff.patchForHunk(hunk, haxe.io.Bytes.ofString(relative)) != null;
		}
		if (action == "unstage") return false;
		var tracker = scmDocumentMarkers.get(view.document.id);
		if (tracker == null) return false;
		var repository = source.repository(tracker.getRepositoryId()), features = repository == null ? null : source.features(tracker.getRepositoryId());
		return repository != null && source.canWrite(repository.id) && features != null && features.partialStaging
			&& source.snapshot(repository.id) != null && tracker.patchForLine(view.selection.cursor.line) != null;
	}
	function applyActiveScmHunk(action:String):Void {
		if (!canApplyActiveScmHunk(action)) return;
		var source = editorSourceControlSource(), view = app.host.activeView();
		if (source == null || view == null) return;
		var repository:Null<scm.ScmRepository> = null, pathBytes:haxe.io.Bytes = null, patch:haxe.io.Bytes = null;
		if (view.diffDocument != null) {
			var diff = view.diffDocument;
			repository = source.repository(diff.repositoryId);
			if (repository == null) return;
			var relative = source.isRemote() ? diff.path : pathUnderScope(repository.root, diff.path);
			if (relative == null) return;
			pathBytes = haxe.io.Bytes.ofString(relative);
			patch = diff.patchForHunk(diff.hunkIndexAtLine(view.selection.cursor.line), pathBytes);
		} else {
			var tracker = scmDocumentMarkers.get(view.document.id);
			if (tracker == null) return;
			repository = source.repository(tracker.getRepositoryId());
			pathBytes = tracker.getPathBytes();
			patch = tracker.patchForLine(view.selection.cursor.line);
		}
		if (repository == null || pathBytes == null || patch == null) return;
		var snapshot = source.snapshot(repository.id);
		if (snapshot == null) return;
		var relativePath = pathBytes.toString();
		var operation:scm.ScmOperation = action == "stage" ? scm.ScmOperation.StagePatch(relativePath, patch) :
			action == "unstage" ? scm.ScmOperation.UnstagePatch(relativePath, patch) : scm.ScmOperation.RevertPatch(relativePath, patch);
		applyScmOperation(source, repository, snapshot, operation);
	}
	function openActiveDiffSourceAtLine():Void {
		var view = activeDiffView(), diff = view == null ? null : view.diffDocument;
		if (view == null || diff == null) return;
		var source = editorSourceControlSource();
		if (source != null && source.isRemote()) {
			var repository = source.repository(diff.repositoryId);
			if (repository != null) openRemoteScmFile(repository, diff.path, diff.sourceLine(view.selection.cursor.line));
		} else app.host.openDiffSourceAtLine();
	}
	function clearLocalScmSource():Void {
		if (panelScm.clear()) app.scmBranches.cancel();
		editorScm.clear();
		sessionScm.clear();
	}
}
