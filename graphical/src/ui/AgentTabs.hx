package ui;



import nativekit.ffi.NativeKitTypes;
import haxeon.ui.Path;


import sys.FileSystem;
import sys.io.File;
import workspace.service.WorkspaceFileProtocol.FileSearchMatch;

/**
	The window's agent session tabs: making a session's tab and the controls its panel uses (folder, branch, worktree,
	images, links, GitHub), and creating sessions with a provider. ExosuitApp owns one.
**/
@:allow(ui)
class AgentTabs {
	final app:ExosuitApp;

	public function new(app:ExosuitApp)
		this.app = app;

	final githubOrigins:Map<String, String> = [];
	final githubOriginsPending:Map<String, Bool> = [];
	final githubOriginsCheckedAt:Map<String, Float> = [];
 function makeAgentTab(id:String,resource:String,root:String,title:String):UiAgentTab {
  var artifactPreviewAvailable = Std.isOfType(app.hostContext, haxeon.ui.host.DesktopUiHostContext) && SessionArtifactPreview.available();
  return new UiAgentTab(id,resource,root,title,new CodexSessionPanel(function() return app.workbenchClient==null?null:app.workbenchClient.agentService(),resource,root,app.requestFrame,app.editorPalette,app.application.syntaxes,app.workbenchActions.showWorkbenchMenu,
   function(group:String) {
    createProviderAgent(app.application.settings.current.defaultAgentProvider, group);
   }, function(destination) openSessionLink(resource, root, destination), {
    explore: function() { if (sessionRecord(resource, root) != null) app.showSidebarMode("files"); },
    reviewChanges: function() { if (sessionRecord(resource, root) != null) app.showSidebarMode("scm"); },
    canCommitChanges: function() return sessionCommitRepository(resource, root) != null,
    commitChanges: function() {
     var repository = sessionCommitRepository(resource, root), source = app.sourceControl.sourceControlSource();
     if (repository == null || source == null) return;
     app.sourceControl.rememberScmResource(source, repository, null, null);
     app.showSidebarMode("scm");
     app.sourceControl.sourceControlPanel();
     if (app.sourceControl.sourceControlPanelValue != null) app.sourceControl.sourceControlPanelValue.focusCommitMessage();
     app.requestFrame();
    },
    context: function() return sessionWorkspaceLabel(resource, root),
    resolveImage: function(destination) return resolveSessionImage(resource, root, destination),
    loadImage: function(destination, done) readSessionImage(resource, root, destination, done),
    openMessageImage: function(turn,item,imageId,bytes) openSentSessionImage(resource,root,turn,item,imageId,bytes),
    readContext: function(path, done) readSessionContext(resource, root, path, done),
    canCreateWorktree: function() return sessionWorktreeRepository(resource, root) != null,
    newWorktree: function() createSessionWorktree(resource, root),
    worktreeLabel: function() return sessionDirectoryLabel(resource, root),
    branchLabel: function() return sessionBranchLabel(resource, root),
    canSelectWorktree: function() return canSelectSessionDirectory(resource, root),
    selectWorktree: function() selectSessionDirectory(resource, root),
    canSelectBranch: function() return sessionBranchSelectable(resource, root),
    selectBranch: function() selectSessionBranch(resource, root),
    chooseImage: app.desktop == null ? null : function(done) chooseSessionImage(resource, root, done),
    pasteImage: app.desktop == null ? null : function() return SessionClipboardImage.read(),
    canOpenGithub: function() return sessionGithubOrigin(resource, root) != null,
    canOpenPullRequest: function() return sessionGithubOrigin(resource, root) != null && sessionGithubBranch(resource, root) != null,
    githubRepository: function() openSessionGithub(resource, root, false),
    githubPullRequest: function() openSessionGithub(resource, root, true),
    previewArtifact: artifactPreviewAvailable ? function(_, source) {
     var desktopHost:haxeon.ui.host.DesktopUiHostContext = cast app.hostContext;
     if (!SessionArtifactPreview.open(desktopHost.window.rawValue(), source))
      app.application.reportError("agent", "Static artifact preview is unavailable or the source exceeds 512 KiB");
    } : null
   }, function() return app.hostContext == null || !app.hostContext.touchPrimary));
 }
 function sessionGithubSource(resource:String, root:String):Null<{source:scm.ScmRemoteReader, repository:scm.ScmRepository}> {
  var record = sessionRecord(resource, root), source = record == null ? null : app.sourceControl.sessionSourceControlSource(record.cwd);
  if (record == null || source == null || !Std.isOfType(source, scm.ScmRemoteReader)) return null;
  var reader:scm.ScmRemoteReader = cast source, nearest:Null<scm.ScmRepository> = null;
  for (repository in source.repositories()) if (reader.canReadOrigin(repository.id)
    && workspace.client.SessionLinkTarget.relativeWithin(repository.root, record.cwd) != null
    && (nearest == null || repository.root.length > nearest.root.length)) nearest = repository;
  return nearest == null ? null : {source:reader, repository:nearest};
 }
 function sessionGithubOrigin(resource:String, root:String):Null<String> {
  var selected = sessionGithubSource(resource, root);
  if (selected == null) return null;
  // An origin belongs to the repository, not to the source viewing it, so switching groups neither refetches nor grows this.
  var key = root + ":" + selected.repository.id;
	  var checked = githubOriginsCheckedAt.get(key);
	  if (checked != null && Sys.time() - checked >= 30) { githubOrigins.remove(key); githubOriginsCheckedAt.remove(key); }
  if (!githubOrigins.exists(key) && !githubOriginsPending.exists(key)) {
   githubOriginsPending.set(key, true);
   selected.source.origin(selected.repository.id, function(result) {
    githubOriginsPending.remove(key);
    var current = sessionGithubSource(resource, root);
    if (current == null || current.source != selected.source || current.repository.id != selected.repository.id) return;
    githubOrigins.set(key, result.error == null && result.value != null ? result.value : "");
	   githubOriginsCheckedAt.set(key, Sys.time());
    app.requestFrame();
   });
  }
  var origin = githubOrigins.get(key);
  return origin == null || origin == "" ? null : origin;
 }
 function sessionGithubBranch(resource:String, root:String):Null<String> {
  var selected = sessionGithubSource(resource, root), source = app.sourceControl.sessionScmSource(resource, root);
  if (selected == null || source == null) return null;
  var snapshot = source.snapshot(selected.repository.id);
  return snapshot == null ? null : snapshot.head.branch;
 }
 function openSessionGithub(resource:String, root:String, pullRequest:Bool):Void {
  var selected = sessionGithubSource(resource, root), branch = pullRequest ? sessionGithubBranch(resource, root) : null;
  if (selected == null || (pullRequest && branch == null)) return;
  selected.source.origin(selected.repository.id, function(result) {
   var current = sessionGithubSource(resource, root);
   if (current == null || current.source != selected.source || current.repository.id != selected.repository.id
     || (pullRequest && branch != sessionGithubBranch(resource, root))) return;
   var url = result.error == null ? result.value : null;
   if (url == null) { app.application.reportError("source-control", "GitHub origin is unavailable"); return; }
   if (pullRequest) url = scm.GithubRemote.pullRequestPage(url, branch);
   if (url == null || nativekit.ffi.NativeKit.nk_shell_open_url(url) != Result.Ok)
    app.application.reportError("source-control", "Could not open GitHub");
  });
 }
 function chooseSessionImage(resource:String, root:String, done:(Null<String>, Null<haxe.io.Bytes>, Null<String>)->Void):Void {
  var dialogs = app.desktop, initial = sessionRecord(resource, root);
  if (dialogs == null || initial == null) { done(null, null, "Image selection is unavailable"); return; }
  dialogs.openFile(function(accepted, paths) {
   if (!accepted || paths == null || paths.length == 0) { done(null, null, null); return; }
   var current = sessionRecord(resource, root);
   if (current == null || current.thread != initial.thread || current.cwd != initial.cwd) { done(null, null, "Session changed while choosing an image"); return; }
   var path = paths[0];
   try {
    var metadata = sys.FileSystem.metadata(path);
    if (metadata == null || metadata.size <= 0 || metadata.size > 2 * 1024 * 1024 || sys.FileSystem.isDirectory(path)) {
     done(null, null, "Choose an image of at most 2 MiB"); return;
    }
    var bytes = sys.io.File.getBytes(path);
    if (bytes.length == 0 || bytes.length > 2 * 1024 * 1024) { done(null, null, "Image is too large"); return; }
    done(haxe.io.Path.withoutDirectory(path), bytes, null);
   } catch (_:Dynamic) done(null, null, "Could not read the selected image");
  }, "Choose an image");
 }
 function readSessionContext(resource:String, root:String, input:String, done:(Null<String>, Null<String>)->Void):Void {
  var record = sessionRecord(resource, root), attachment = app.workspaceAttachment;
  var target = workspace.client.SessionLinkTarget.parse(input);
  if (record == null || target == null || target.line >= 0 || StringTools.startsWith(target.path, "/")
      || ~/^[A-Za-z]:/.match(target.path) || StringTools.startsWith(target.path, "\\")) {
   done(null, "Choose a relative file path in this workspace"); return;
  }
  var path = target.resolve(record.cwd);
  var localFiles = attachment == null || attachment.hasLocalFileAccess();
  if (!workspace.client.SessionFileScope.allows(root, record.cwd, path, localFiles, workspace.client.SessionLinkTarget.relativeWithin)) {
   done(null, "File is outside this workspace"); return;
  }
  function wanted():Bool {
   var current = sessionRecord(resource, root);
   return app.workspaceAttachment == attachment && current != null && current.cwd == record.cwd && current.thread == record.thread;
  }
  if (attachment != null && !attachment.hasLocalFileAccess()) {
   var client = attachment.fileClient(), scope = app.servedFolders.primaryScope(attachment);
   var relative = scope == null ? null : workspace.client.SessionLinkTarget.relativeWithin(scope, path);
   if (client == null || relative == null) { done(null, "Workspace file service is unavailable"); return; }
   var workspaceId = attachment.fileWorkspace();
   client.stat(workspaceId, "root", relative, function(stat) {
    if (!wanted()) { done(null, "Session changed while reading the file"); return; }
    if (stat == null || stat.workspace != workspaceId || stat.root != "root" || stat.path != relative || stat.entry == null
      || stat.entry.kind != "file" || stat.entry.revision == null || stat.entry.size == null
      || haxe.Int64.compare(stat.entry.size, haxe.Int64.ofInt(4096)) > 0 || haxe.Int64.compare(stat.entry.size, haxe.Int64.ofInt(0)) < 0) {
     done(null, "Choose a text file of at most 4096 bytes"); return;
    }
    WorkspaceFileReader.read(client, workspaceId, "root", relative, stat.entry.revision, function(result) {
     if (!wanted()) done(null, "Session changed while reading the file");
     else if (result.error != null || result.sizeBytes > 4096) done(null, result.error == null ? "File is too large" : result.error);
     else done(result.contents, null);
    }, wanted);
   }, function(error) done(null, error == null ? "Could not read workspace file" : error.message));
  } else try {
   var fs = app.application.workspace.fileSystem;
   if (!fs.exists(path) || fs.isDirectory(path)) { done(null, "File is unavailable"); return; }
   path = fs.normalize(path);
   if (!workspace.client.SessionFileScope.allows(root, record.cwd, path, true, app.sourceControl.scmRelativePath)) { done(null, "File is outside this workspace"); return; }
   var metadata = sys.FileSystem.metadata(path);
   if (metadata == null || metadata.size < 0 || metadata.size > 4096) { done(null, "Choose a text file of at most 4096 bytes"); return; }
   var bytes = sys.io.File.getBytes(path);
   if (bytes.length > 4096) { done(null, "File is too large"); return; }
   done(workspace.TextFileContent.decode(bytes, path), null);
  } catch (_:Dynamic) done(null, "Could not read a UTF-8 text file");
 }
 function sessionRecord(resource:String, root:String):Null<workspace.service.WorkspaceAgentProtocol.AgentRecord> {
  var client = app.workbenchClient == null ? null : app.workbenchClient.agentService();
  var catalog = client == null ? null : client.agents();
  if (catalog == null || catalog.root != root) return null;
  var view = client.agentView(resource);
  return view == null ? null : view.record;
 }
 function sessionWorkspaceLabel(resource:String, root:String):String {
  var record = sessionRecord(resource, root);
  if (record == null) return "Workspace disconnected";
  var label = record.cwd;
  var source = app.sourceControl.sessionSourceControlSource(record.cwd);
  if (source != null) {
   var nearest:Null<scm.ScmRepository> = null;
   for (repository in source.repositories())
    if (workspace.client.SessionLinkTarget.relativeWithin(repository.root, record.cwd) != null && (nearest == null || repository.root.length > nearest.root.length)) nearest = repository;
   var snapshot = nearest == null ? null : source.snapshot(nearest.id);
   if (snapshot != null && snapshot.head.branch != null) label += " · " + snapshot.head.branch;
  }
  return label;
 }
 function nearestSessionGitRepository(resource:String, root:String):Null<scm.ScmRepository> {
  var record = sessionRecord(resource, root), source = record == null ? null : app.sourceControl.sessionSourceControlSource(record.cwd);
  if (record == null || source == null || !source.connected()) return null;
  var nearest:Null<scm.ScmRepository> = null, local = app.sourceControl.sessionLocalFiles();
  for (repository in source.repositories()) if (repository.providerId == "git"
    && workspace.client.SessionFileScope.allowsRepository(root, record.cwd, repository.root, local, workspace.client.SessionLinkTarget.relativeWithin)
    && (nearest == null || repository.root.length > nearest.root.length)) nearest = repository;
  return nearest;
 }
 function sessionDirectoryLabel(resource:String, root:String):String {
  var record = sessionRecord(resource, root);
  if (record == null) return "Directory unavailable";
  var path = StringTools.replace(record.cwd, "\\", "/");
  while (path.length > 1 && StringTools.endsWith(path, "/")) path = path.substr(0, path.length - 1);
  var name = path.substr(path.lastIndexOf("/") + 1);
  return name == "" ? path : name;
 }
 function sessionBranchLabel(resource:String, root:String):String {
  var repository = nearestSessionGitRepository(resource, root), source = app.sourceControl.sessionScmSource(resource, root);
  if (repository == null || source == null) return "Branch unavailable";
  var snapshot = source.snapshot(repository.id);
  if (snapshot == null) return "Branch unavailable";
  if (snapshot.head.branch != null && snapshot.head.branch != "") return snapshot.head.branch;
  return snapshot.head.detachedCommit == null ? "Branch unavailable" : "Detached HEAD";
 }
 function sessionBranchSelectable(resource:String, root:String):Bool {
  var client = app.workbenchClient == null ? null : app.workbenchClient.agentService();
  var view = client == null ? null : client.agentView(resource);
  var repository = nearestSessionGitRepository(resource, root);
  return sessionRecord(resource, root) != null && client != null && client.canControlAgents() && !client.agentBusy()
   && view != null && ["idle", "completed", "failed", "interrupted"].indexOf(view.record.state) >= 0
   && (view.connectionState == null || view.connectionState == "connected") && view.requests.length == 0
   && repository != null && app.sourceControl.canCheckoutScmRepository(repository, app.sourceControl.sessionScmSource(resource, root));
 }
 function selectSessionBranch(resource:String, root:String):Void {
  if (!sessionBranchSelectable(resource, root)) return;
  var client = app.workbenchClient, source = app.sourceControl.sessionScmSource(resource, root), record = sessionRecord(resource, root);
  var repository = nearestSessionGitRepository(resource, root);
  var agents = client == null ? null : client.agentService(), catalog = agents == null ? null : agents.agents();
  var terminals = client == null ? null : client.terminalCatalog();
  if (client == null || source == null || record == null || repository == null || catalog == null || terminals == null
    || catalog.root != root || terminals.workspaceRoot != root) return;
  var instance = catalog.instance, terminalInstance = terminals.instance, repositoryId = repository.id;
  var thread = record.thread, cwd = record.cwd, group = record.group, provider = record.provider;
  function valid():Bool {
   var currentAgents = app.workbenchClient == null ? null : app.workbenchClient.agentService();
   var currentCatalog = currentAgents == null ? null : currentAgents.agents();
   var currentTerminals = app.workbenchClient == null ? null : app.workbenchClient.terminalCatalog();
   var current = sessionRecord(resource, root), selected = nearestSessionGitRepository(resource, root);
   return app.workbenchClient == client && currentAgents == agents && app.sourceControl.sessionScmSource(resource, root) == source
    && currentCatalog != null && currentCatalog.instance == instance && currentCatalog.root == root
    && currentTerminals != null && currentTerminals.instance == terminalInstance && currentTerminals.workspaceRoot == root
    && current != null && current.thread == thread && current.cwd == cwd && current.group == group && current.provider == provider
    && selected != null && selected.id == repositoryId && sessionBranchSelectable(resource, root);
  }
  if (valid()) app.scmBranches.open(repository, valid, source);
 }
 function canSelectSessionDirectory(resource:String, root:String):Bool {
  var client = app.workbenchClient, record = sessionRecord(resource, root);
  var catalog = client == null ? null : client.terminalCatalog();
  if (client == null || record == null || catalog == null || catalog.workspaceRoot != root
   || !client.agentService().canControlAgents() || client.agentService().agentCreation() != null) return false;
  if (sessionWorktreeRepository(resource, root) != null) return true;
  for (candidate in catalog.groups)
   if (SessionGroupDirectory.resolve(catalog.groups, root, candidate.id, record.provider) != null) return true;
  return false;
 }
 /** Starts a new session in an existing group; it never retargets this native thread. */
 function selectSessionDirectory(resource:String, root:String):Void {
  if (!canSelectSessionDirectory(resource, root)) return;
  var client = app.workbenchClient, record = sessionRecord(resource, root);
  if (client == null || record == null) return;
  var catalog:Null<workspace.service.WorkspaceTerminalProtocol.TerminalCatalog> = client.terminalCatalog();
  if (catalog == null) return;
  var source = app.sourceControl.sessionSourceControlSource(record.cwd), owner = catalog.instance;
  var thread = record.thread, cwd = record.cwd, provider = record.provider, group = record.group;
  var entries:Array<commandview.CommandViewEntry> = [];
  var offered:Map<String,{cwd:String, stamp:String}> = [];
  if (sessionWorktreeRepository(resource, root) != null)
   entries.push(new commandview.CommandViewEntry("New worktree…", "Create a worktree and start a new session", "@new"));
  for (candidate in catalog.groups) {
   var resolved = SessionGroupDirectory.resolve(catalog.groups, root, candidate.id, provider);
   if (resolved == null) continue;
   offered.set(candidate.id, resolved);
   entries.push(new commandview.CommandViewEntry("New session in " + candidate.name, resolved.cwd, "group:" + candidate.id));
  }
  if (entries.length == 0) return;
  app.host.openCommandView(new commandview.CommandViewProvider("New session directory: ", entries, function(_) {}, function(entry, _, _) {
   app.host.closeCommandView();
   var current = sessionRecord(resource, root), latest = client.terminalCatalog();
   if (entry == null || app.workbenchClient != client || current == null || app.sourceControl.sessionSourceControlSource(current.cwd) != source
     || current.thread != thread || current.cwd != cwd || current.provider != provider || current.group != group
     || latest == null || latest.instance != owner || latest.workspaceRoot != root || !canSelectSessionDirectory(resource, root)) return;
   if (entry.value == "@new") { if (sessionWorktreeRepository(resource, root) != null) createSessionWorktree(resource, root); return; }
   if (!StringTools.startsWith(entry.value, "group:")) return;
   var id = entry.value.substr(6);
   var candidate = offered.get(id);
   if (candidate != null) {
    var fresh = SessionGroupDirectory.resolve(latest.groups, root, id, provider);
    if (fresh != null && fresh.cwd == candidate.cwd && fresh.stamp == candidate.stamp) {
     createIntegratedAgent(provider == null ? "codex" : provider, id); return;
    }
   }
  }));
  app.requestFrame();
 }
 function sessionCommitRepository(resource:String, root:String):Null<scm.ScmRepository> {
  var record = sessionRecord(resource, root), source = record == null ? null : app.sourceControl.sessionSourceControlSource(record.cwd);
  if (record == null || source == null || !source.connected()) return null;
  var nearest:Null<scm.ScmRepository> = null, local = app.sourceControl.sessionLocalFiles();
  for (repository in source.repositories()) if (repository.providerId == "git" && source.canWrite(repository.id)
    && workspace.client.SessionFileScope.allowsRepository(root, record.cwd, repository.root, local, workspace.client.SessionLinkTarget.relativeWithin)
    && source.snapshot(repository.id) != null && (nearest == null || repository.root.length > nearest.root.length)) nearest = repository;
  return nearest;
 }
 function sessionWorktreeRepository(resource:String, root:String):Null<scm.ScmRepository> {
  var record = sessionRecord(resource, root), client = app.workbenchClient;
  var source = record == null ? null : app.sourceControl.sessionSourceControlSource(record.cwd), local = app.sourceControl.sessionLocalFiles();
  if (record == null || source == null || client == null || !source.connected() || !client.canEditGroups()
    || client.terminalCatalogBusy() || !client.agentService().canControlAgents() || client.agentService().agentCreation() != null) return null;
  var nearest:Null<scm.ScmRepository> = null;
  for (repository in source.repositories()) {
   var features = source.features(repository.id);
   if (repository.providerId == "git" && features != null && features.worktrees && source.canWrite(repository.id)
     && workspace.client.SessionFileScope.allowsRepository(root, record.cwd, repository.root, local, workspace.client.SessionLinkTarget.relativeWithin)
     && source.snapshot(repository.id) != null && (nearest == null || repository.root.length > nearest.root.length)) nearest = repository;
  }
  return nearest;
 }
 function createSessionWorktree(resource:String, root:String):Void {
  var record = sessionRecord(resource, root), repository = sessionWorktreeRepository(resource, root), source = app.sourceControl.sessionScmSource(resource, root);
  var client = app.workbenchClient, catalog = client == null ? null : client.terminalCatalog();
  if (record == null || repository == null || source == null || client == null || catalog == null) return;
  var owner = catalog.instance, provider = record.provider == null ? "codex" : record.provider;
  function valid():Bool {
   var current = client.terminalCatalog(), session = sessionRecord(resource, root);
   return app.workbenchClient == client && session != null && app.sourceControl.sessionSourceControlSource(session.cwd) == source
    && session.cwd == record.cwd && session.thread == record.thread && session.provider == record.provider && session.group == record.group
    && current != null && current.instance == owner;
  }
  app.host.openCommandView(new commandview.CommandViewProvider("New worktree branch: ", [], function(_) {}, function(_, branch, _) {
   app.host.closeCommandView();
   branch = StringTools.trim(branch);
   if (!valid()) return;
   if (branch.length == 0 || branch.length > 128 || branch.charAt(0) == "-" || ~/[\x00-\x20\x7f]/.match(branch)) {
    app.application.reportError("agent", "Enter a valid branch name of at most 128 characters"); return;
   }
   app.host.openCommandView(new commandview.CommandViewProvider("New worktree folder name inside repository: ", [], function(_) {}, function(_, directory, _) {
    app.host.closeCommandView(); directory = StringTools.trim(directory);
    if (!valid()) { app.application.reportError("agent", "Workspace changed before worktree creation"); return; }
    var current = source.snapshot(repository.id);
    var selected = sessionWorktreeRepository(resource, root);
    if (current == null || selected == null || selected.id != repository.id) { app.application.reportError("agent", "Repository is unavailable or changed"); return; }
    var destination = repository.root + "/" + directory;
    source.apply(repository.id, workspace.client.WorkspaceIds.create("worktree"), current.revision,
      scm.ScmOperation.CreateWorktree(directory, branch), function(result) {
       if (result.error != null) { app.application.reportError("agent", result.error.message); app.requestFrame(); return; }
       if (!valid()) { app.application.reportError("agent", "Worktree created at " + destination + "; workspace changed before a session group could be created"); app.requestFrame(); return; }
       var group:workspace.service.WorkspaceProtocol.WorkspaceGroup = {id:workspace.client.WorkspaceIds.create("group"), name:branch, cwd:destination, revision:0};
       client.changeGroup(owner, group, branch, null, destination, 0, true, function(created, error) {
        if (error != null || created == null) app.application.reportError("agent", "Worktree created at " + destination + "; could not create its session group: " + (error == null ? "unknown error" : error));
        else if (!valid()) app.application.reportError("agent", "Worktree and group created at " + destination + "; reconnect to start a session");
        else createIntegratedAgent(provider, created.id);
        app.requestFrame();
       });
      });
   }));
  }));
 }
 function resolveSessionImage(resource:String, root:String, destination:String):Null<String> {
  var record = sessionRecord(resource, root);
  if (record == null || (app.workspaceAttachment != null && !app.workspaceAttachment.hasLocalFileAccess())) return null;
  var target = workspace.client.SessionLinkTarget.parse(destination);
  if (target == null || !UiImageTab.supports(target.path)) return null;
  var path = target.resolve(record.cwd);
  try {
   if (!app.application.workspace.fileSystem.exists(path) || app.application.workspace.fileSystem.isDirectory(path)) return null;
   path = app.application.workspace.fileSystem.normalize(path);
   if (!workspace.client.SessionFileScope.allows(root, record.cwd, path, true, app.sourceControl.scmRelativePath)) return null;
   var metadata = sys.FileSystem.metadata(path);
   return metadata != null && metadata.size <= 4 * 1024 * 1024 ? path : null;
  } catch (_:Dynamic) return null;
 }
 function openSentSessionImage(resource:String,root:String,turn:String,item:String,imageId:String,bytes:haxe.io.Bytes):Void {
  if(sessionRecord(resource,root)==null) {app.application.reportError("agent","Reconnect this session to open its image");return;}
  var image:Null<haxeon.ui.Image>=null;
  try {
   var dimensions=SessionImageProbe.dimensions(bytes);
   if(dimensions==null) throw "Unsupported or invalid sent image";
   var digest=haxe.crypto.Sha256.make(bytes), fingerprint="";
   for(index in 0...digest.length) fingerprint+=StringTools.hex(digest.get(index),2);
   var identity="sent-image:"+root.length+":"+root+resource.length+":"+resource+turn.length+":"+turn+item.length+":"+item+imageId.length+":"+imageId+":"+fingerprint;
   if(app.host.activateRemoteImage(identity)) {app.requestFrame();return;}
   if(!app.host.canOpenRemoteImage(dimensions.width,dimensions.height)) throw "Image memory limit reached; close an image and try again";
   image=SessionImageProbe.decodeFull(bytes);
   if(image==null) throw "Unsupported or invalid sent image";
   app.host.openRemoteImage(identity,"Sent image",image,bytes.length,"session");image=null;
  } catch(problem:Dynamic) {if(image!=null) image.dispose();app.application.reportError("agent",Std.string(problem));}
  app.requestFrame();
 }
 function readSessionImage(resource:String, root:String, destination:String, done:(Null<haxe.io.Bytes>, Null<String>)->Void):Void {
  var record = sessionRecord(resource, root), attachment = app.workspaceAttachment;
  var target = workspace.client.SessionLinkTarget.parse(destination);
  if (attachment == null || attachment.hasLocalFileAccess()) {
   try {
    var local = resolveSessionImage(resource, root, destination);
    var bytes = local == null ? null : SessionImageProbe.readBounded(local);
    done(bytes, bytes == null ? "Image preview is unavailable for this location" : null);
   } catch (_:Dynamic) done(null, "Could not read workspace image");
   return;
  }
  if (record == null || attachment == null || attachment.hasLocalFileAccess() || target == null || target.line >= 0) {
   done(null, "Image preview is unavailable for this location"); return;
  }
  var cwd = record.cwd, thread = record.thread, path = target.resolve(cwd);
  var scope = app.servedFolders.primaryScope(attachment), client = attachment.fileClient();
  var relative = scope == null ? null : workspace.client.SessionLinkTarget.relativeWithin(scope, path);
  if (client == null || relative == null || workspace.client.SessionLinkTarget.relativeWithin(root, path) == null) {
   done(null, "Image is outside the connected workspace"); return;
  }
  var workspaceId = attachment.fileWorkspace();
  function wanted():Bool {
   var current = sessionRecord(resource, root);
   return app.workspaceAttachment == attachment && current != null && current.cwd == cwd && current.thread == thread
    && attachment.fileClient() == client && attachment.fileWorkspace() == workspaceId && app.servedFolders.primaryScope(attachment) == scope;
  }
  WorkspaceImageReader.read(client, workspaceId, "root", relative, done, wanted);
 }
 /** Route explicit file links to the owning workspace; external URLs require activation. */
 function openSessionLink(resource:String, root:String, destination:String):Void {
  var record = sessionRecord(resource, root);
  if (record == null) { app.application.reportError("agent", "Reconnect this session’s workspace to open its links"); return; }
  if (workspace.client.SessionLinkTarget.external(destination)) {
   try {
    if (nativekit.ffi.NativeKit.nk_shell_open_url(destination) != Result.Ok)
     app.application.reportError("agent", "Could not open link");
   } catch (error:Dynamic) app.application.reportError("agent", Std.string(error));
   return;
  }
  var target = workspace.client.SessionLinkTarget.parse(destination);
  if (target == null) return;
  var path = target.resolve(record.cwd);
  // A response is workspace content: never resolve a stale/remote host path locally.
  var attachment = app.workspaceAttachment;
  var remote = attachment != null && !attachment.hasLocalFileAccess();
  // Locally the session's own folder counts too: a group folder may lie outside the workspace. A remote attachment's
  // file service shares only the workspace root.
  var allowed = remote
   ? workspace.client.SessionFileScope.allows(root, record.cwd, path, false, workspace.client.SessionLinkTarget.relativeWithin)
   : workspace.client.SessionFileScope.allows(root, record.cwd, path, true, app.sourceControl.scmRelativePath);
  if (!allowed) { app.application.reportError("agent", "This file link is outside the session’s workspace"); return; }
  if (remote) {
   var client = attachment.fileClient(), scope = app.servedFolders.primaryScope(attachment);
   if (client == null || scope == null) { app.application.reportError("agent", "Workspace file service is unavailable"); return; }
   var scopedPath = workspace.client.SessionLinkTarget.relativeWithin(scope, path);
   if (scopedPath == null) { app.application.reportError("agent", "This file is outside the connected file root"); return; }
   var workspaceId = attachment.fileWorkspace();
   if (UiImageTab.supports(scopedPath)) {
    readSessionImage(resource, root, destination, function(bytes, error) {
     if (error != null || bytes == null) { app.application.reportError("agent", error == null ? "Could not load workspace image" : error); app.requestFrame(); return; }
     var image:Null<haxeon.ui.Image> = null;
     try {
      var digest = haxe.crypto.Sha256.make(bytes), fingerprint = "";
      for (index in 0...digest.length) fingerprint += StringTools.hex(digest.get(index), 2);
      var identity = "remote-image:" + workspaceId.length + ":" + workspaceId + scope.length + ":" + scope
       + scopedPath.length + ":" + scopedPath + ":" + fingerprint;
      if (app.host.activateRemoteImage(identity)) { app.requestFrame(); return; }
      var dimensions = SessionImageProbe.dimensions(bytes);
      if (dimensions == null) throw "Unsupported or invalid workspace image";
      if (!app.host.canOpenRemoteImage(dimensions.width, dimensions.height)) throw "Remote image memory limit reached; close an image and try again";
      image = SessionImageProbe.decodeFull(bytes);
      if (image == null) throw "Unsupported or invalid workspace image";
      app.host.openRemoteImage(identity, scopedPath, image, bytes.length);
      image = null;
     } catch (error:Dynamic) { if (image != null) image.dispose(); app.application.reportError("agent", Std.string(error)); }
     app.requestFrame();
    });
    return;
   }
   client.stat(workspaceId, "root", scopedPath, function(stat) {
    var current = sessionRecord(resource, root);
    if (app.workspaceAttachment != attachment || current == null || current.cwd != record.cwd || current.thread != record.thread) return;
    if (stat == null || stat.workspace != workspaceId || stat.root != "root" || stat.path != scopedPath
      || stat.entry == null || stat.entry.kind != "file" || stat.entry.revision == null) {
     app.application.reportError("agent", "The linked workspace file is no longer available"); app.requestFrame(); return;
    }
    var match:Null<FileSearchMatch> = target.line < 0 ? null : {path: scopedPath, kind: "file", revision: stat.entry.revision,
     line: target.line, column: target.column, length: 0, preview: ""};
    app.remoteFileTabs.openWorkspaceFileSnapshot(attachment, workspaceId, scope, "root", scope, scopedPath, stat.entry.revision,
     WorkspaceFileReader.previewSize(stat.entry.size), false, match);
    app.requestFrame();
   }, function(error) { if (app.workspaceAttachment == attachment) app.application.reportError("agent", error == null ? "Could not open workspace file" : error.message); app.requestFrame(); });
  } else {
   try {
    if (!app.application.workspace.fileSystem.exists(path) || app.application.workspace.fileSystem.isDirectory(path)) {
     app.application.reportError("agent", "The linked file is no longer available"); return;
    }
    app.host.openFile(path, true);
    var view = app.host.activeView();
    if (view != null && target.line >= 0) { view.restoreCursor(target.line, target.column); app.host.cursorChanged(); }
    app.host.focusActiveEditor();
    app.requestFrame();
   } catch (error:Dynamic) app.application.reportError("agent", "Could not open file: " + Std.string(error));
  }
 }
 function canCreateAgentSession():Bool
  return canCreateSession(app.application.settings.current.agentSessionMode == "terminal");
 /** Whether a session can start now: as an agent terminal (`terminal`) or in the chat view. */
 function canCreateSession(terminal:Bool):Bool {
  var client = app.workbenchClient;
  if (client == null) return false;
  if (terminal) return client.canCreateGroupedTerminals() && !client.terminalCatalogBusy();
  return client.agentService().canControlAgents() && client.agentService().agentCreation() == null;
 }
 /** New Chat With…: a `provider` session in `group` of the open workspace, in the chat view even in terminal session mode. */
 function createProviderChat(provider:String, group:String):Void createProviderAgentIn(provider, group, sessionDirectory(group), true);
 /**
  New Agent Session: a `provider` session in `group` of the open workspace, at once and with no dialog (Workbench
  design Q7), in the folder the group gives it.
 **/
 function createProviderAgent(provider:String, group:String):Void createProviderAgentIn(provider, group, sessionDirectory(group));
 /**
  The folder to send for a new session or terminal in `group`: null lets the service resolve it, as it does from the
  group's folder, else the workspace's first. A service keeps the folder it started in, so one started in the scratch
  folder is sent the attached folder explicitly.
 **/
 function sessionDirectory(group:String):Null<String> {
  var catalog = app.workbenchClient == null ? null : app.workbenchClient.terminalCatalog();
  if (catalog == null || app.workbenchPanel == null) return null;
  var resolved = SessionFolderChooser.preview(catalog.groups, group, app.workbenchPanel.model.firstFolder(app.workbenchPanel.model.openWorkspace), catalog.workspaceRoot);
  return SessionFolderChooser.explicitFor(catalog.groups, group, resolved, catalog.workspaceRoot);
 }
 /** New Agent Session With… › Change Folder…: picks the folder, then starts a `provider` session there. */
 function chooseSessionFolder(provider:String, group:String):Void {
  var catalog = app.workbenchClient == null ? null : app.workbenchClient.terminalCatalog();
  var initial = catalog == null || app.workbenchPanel == null ? null
   : SessionFolderChooser.preview(catalog.groups, group, app.workbenchPanel.model.firstFolder(app.workbenchPanel.model.openWorkspace), catalog.workspaceRoot);
  app.workbenchActions.chooseFolder("Choose the Session's Folder", initial, function(folder) createProviderAgentIn(provider, group, folder));
 }
 /**
  `directory` is the folder chosen with Change Folder…, or the one `sessionDirectory` gives; null lets the service
  resolve it. `chat` starts it in the chat view whatever the session mode setting says.
 **/
 function createProviderAgentIn(provider:String, group:String, directory:Null<String>, chat:Bool = false):Void {
  // New Agent Session in the connect timeline; a terminal session ends at terminal-attached (it accepts input).
  workspace.client.ConnectTimeline.mark("new-agent-session", app.currentWorkspaceName(), provider);
  var terminal = !chat && app.application.settings.current.agentSessionMode == "terminal";
  if (!canCreateSession(terminal)) {
   app.application.reportError("agent", "Cannot create an agent session while the workspace is disconnected or another session operation is in progress. Wait and try again.");
   app.requestFrame(); return;
  }
  if (terminal) { createAgentTerminal(provider, group, directory); return; }
  createIntegratedAgent(provider, group, directory);
 }
 function createIntegratedAgent(provider:String, group:String, ?directory:String):Void {
  var client=app.workbenchClient;
  if(client == null || !client.agentService().canControlAgents() || client.agentService().agentCreation() != null) {
   app.application.reportError("agent", "The worktree group is ready; connect to start an integrated session"); return;
  }
  var defaults:workspace.client.AgentSessionDefaults={provider:provider,model:null,effort:null,
   permissionProfile:provider == "claude" ? "default" : "supervised",directory:directory};
  if(provider == "codex") {
   var settings=app.application.settings.current,model=StringTools.trim(settings.codexDefaultModel);
   defaults.model=model == "" ? null : model;
   defaults.effort=settings.codexDefaultEffort == "model-default" ? null : settings.codexDefaultEffort;
   defaults.permissionProfile=settings.codexDefaultPermissions;
  }
  client.agentService().createAgent(group,null,openCreatedAgent,defaults);
 }
 function createAgentTerminal(provider:String, group:String, ?directory:String):Void {
  var client = app.workbenchClient, catalog = client == null ? null : client.terminalCatalog();
  if (catalog == null || catalog.agentProviders == null || catalog.agentProviders.indexOf(provider) < 0) {
   app.application.reportError("agent", "This workspace service cannot start " + provider + " agent terminals"); return;
  }
  var terminal = app.terminalTabs.newTerminalTab(group, provider, directory);
  if (terminal != null) app.terminalTabs.showTerminalInEditor(terminal);
 }
 function syncWorkbenchSessionSelection(tab:Null<UiEditorTab>):Void {
  if(app.workbenchPanel == null) return;
  var agent=tab == null ? null : UiEditorTabs.agent(tab);
  var terminal=tab == null ? null : UiEditorTabs.terminal(tab);
  var shown=app.workbenchPanel.model.openWorkspace;
  if(agent != null) app.workbenchPanel.syncActiveSession(WorkbenchRowKey.agent(shown == null ? "" : shown,agent.resource));
  else if(terminal != null && terminal.remote) app.workbenchPanel.syncActiveSession(app.terminalTabs.terminalRow(terminal));
  else app.workbenchPanel.syncActiveSession(null);
 }
 function openCreatedAgent(record:workspace.service.WorkspaceAgentProtocol.AgentRecord):Void {
  var client=app.workbenchClient;
  if(client == null) return;
  var groups=client.terminalCatalog();
  if(groups != null && groups.workspaceRoot != record.workspaceRoot) return;
  if(groups != null) app.application.activeContext.openSessionGroup(record.group,groups.groups,record.workspaceRoot);
  var id=ResourceViewIdentity.view(record.workspaceRoot,record.id,"agent");
  app.host.attachAgent(makeAgentTab(id,record.id,record.workspaceRoot,record.name));
  if (app.phoneLayoutActive && app.sidebar.visible) app.sidebar.setVisible(false);
  app.requestFrame();
 }
 public function openCodexAgent(resource:String):Void {
  var client=app.workbenchClient,catalog=client == null ? null : client.agentService().agents();
  if(catalog == null) return;
  for(record in catalog.records) if(record.id == resource) {openCreatedAgent(record);return;}
 }
}
