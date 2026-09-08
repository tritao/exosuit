package core;

import command.CommandContext;
import command.CommandRegistry;
import command.EditorCommands;
import command.Keymap;
import editor.Document;
import renderer.Renderer;
import view.RootView;
import view.View;
import plugin.PluginManager;
import syntax.BuiltinSyntax;
import syntax.SyntaxRegistry;
import style.Theme;
import workspace.Workspace;
import workspace.FileOperations;
import workspace.TrashService;
import sys.FileSystem;
import search.SearchMatch;
import search.SearchOptions;
import search.WorkspaceSearch;
import search.WorkspaceReplacement;
import search.ReplacementPreview;
import search.ReplacementResult;
import config.ConfigurationPaths;
import config.Settings;
import config.SettingsService;
import recovery.RecoveryStore;
import feedback.ErrorLog;
import feedback.ConfirmationService;
import feedback.NotificationKind;
import completion.CompletionRegistry;
import completion.DocumentWordCompletionProvider;
import controller.SearchController;
import controller.FileController;
import controller.ConfigurationController;
import controller.PluginController;
import controller.SessionController;
import controller.WorkbenchController;
import process.ProcessManager;
import controller.BuildController;
import controller.LanguageController;
import session.RecentProjects;

class Application {
	public final documents:DocumentManager;
	public final workspace:Workspace;
	public final fileOperations:FileOperations;
	public final focus:FocusManager;
	public final root:RootView;
	public final commands:CommandRegistry;
	public final keymap:Keymap;
	public final context:CommandContext;
	public final plugins:PluginManager;
	public final pluginController:PluginController;
	public final syntaxes:SyntaxRegistry;
	public final completions:CompletionRegistry;
	public final theme:Theme;
	public final search:SearchController;
	public final files:FileController;
	public final configuration:ConfigurationController;
	public final session:SessionController;
	public final workbench:WorkbenchController;
	public final processes:ProcessManager;
	public final build:BuildController;
	public final language:LanguageController;
	public final searchOptions:SearchOptions;
	public final workspaceSearch:WorkspaceSearch;
	public final workspaceReplacement:WorkspaceReplacement;
	public var replacementPreview(get, never):Null<ReplacementPreview>;
	public var replacementResult(get, never):Null<ReplacementResult>;
	public final settings:SettingsService;
	public final recovery:RecoveryStore;
	public final errors:ErrorLog;
	public final confirmations:ConfirmationService;
	public final recentProjects:RecentProjects;
	public final documentMatches:Array<SearchMatch>;
	public var documentSearchQuery(get, never):String;
	public var quitReady(get, never):Bool;

	public function new(renderer:Renderer, width:Int, height:Int, ?settings:SettingsService, ?recentProjects:RecentProjects) {
		this.settings = settings == null ? new SettingsService() : settings;
		syntaxes = new SyntaxRegistry();
		BuiltinSyntax.install(syntaxes);
		completions = new CompletionRegistry();
		completions.add("core", new DocumentWordCompletionProvider());
		theme = new Theme();
		workspace = new Workspace(syntaxes);
		processes = new ProcessManager();
		fileOperations = new FileOperations(workspace, new TrashService(ConfigurationPaths.trash(), workspace.fileSystem));
		documents = workspace.documents;
		focus = new FocusManager();
		root = new RootView(renderer, theme, focus, workspace, width, height, this.settings.current);
		errors = new ErrorLog();
		confirmations = new ConfirmationService(root.commandView);
		this.recentProjects = recentProjects == null ? new RecentProjects(ConfigurationPaths.recentProjects()) : recentProjects;
		root.closeRequest = function() {
			requestCloseActiveTab();
		};
		commands = new CommandRegistry();
		keymap = new Keymap(commands);
		context = new CommandContext(root, focus, documents);
		EditorCommands.install(commands, keymap);
		search = new SearchController(workspace, root, context, commands, keymap, confirmations, effectiveSettings, reportError,
			reportInformation, ConfigurationPaths.replacementBackup());
		searchOptions = search.options;
		workspaceSearch = search.workspaceSearch;
		workspaceReplacement = search.workspaceReplacement;
		documentMatches = search.documentMatches;
		configuration = new ConfigurationController(this.settings, workspace, root, context, commands, keymap, theme, search, reportError);
		session = new SessionController(this, workspace, root, commands, reportError);
		recovery = session.recovery;
		files = new FileController(documents, workspace, fileOperations, root, context, commands, confirmations, recovery,
			path -> { open(path); }, function() { newDocument(); }, function() { recovery.save(this); }, reportError, reportInformation);
		pluginController = new PluginController(commands, keymap, context, syntaxes, completions, root.pluginPanels, workspace.jobs,
			effectiveSettings, root, processes, reportError, reportInformation);
		plugins = pluginController.manager;
		workbench = new WorkbenchController(workspace, root, commands, keymap, context, completions, errors, search,
			path -> { open(path); });
		workbench.openPath = function(path) { openArgument(path); };
		build = new BuildController(workspace, root, context, commands, processes, path -> open(path), reportError);
		var languageServer = Sys.getEnv("HAXEON_LSP");
		if (languageServer == null || languageServer.length == 0) {
			var bundled = config.ApplicationPaths.bundledLanguageServer();
			if (sys.FileSystem.exists(bundled))
				languageServer = bundled;
			else {
				var haxeonRoot = Sys.getEnv("HAXEON_ROOT");
				if (haxeonRoot == null || haxeonRoot.length == 0) haxeonRoot = "../realtime-haxe";
				languageServer = haxeonRoot + "/scripts/haxeon-lsp";
			}
		}
		language = new LanguageController(workspace, root, context, commands, processes, languageServer, reportError);
		root.welcome.recentProjects = this.recentProjects.paths;
		root.welcome.newFile = function() { newDocument(); };
		root.welcome.openFile = function() { workbench.openPathCommandView(false); };
		root.welcome.openProject = function() { workbench.openPathCommandView(true); };
		root.welcome.findFile = function() { workbench.openFileCommandView(); };
		root.welcome.runCommand = function() { workbench.openCommandView(); };
		root.welcome.openSettings = function() { configuration.openSettingsCommandView(); };
		root.welcome.openPlugins = function() { pluginController.openDiagnostics(); };
		root.welcome.openRecent = function(path) { openArgument(path); };
		root.createFileRequest = function() { files.openCreateFile(); };
		root.createFolderRequest = function() { files.openCreateFolder(); };
		root.renameFileRequest = function() { files.openRenameFile(); };
		root.deleteFileRequest = function() { files.openDeleteFile(); };
	}

	public function open(path:String):View
		return root.openDocument(documents.open(path));

	public function openArgument(path:String):Null<View> {
		if (FileSystem.isDirectory(path)) {
			var normalized = workspace.fileSystem.normalize(path);
			var projectSettings = settings.forProject(ConfigurationPaths.projectSettings(normalized));
			var project = workspace.addProject(normalized, projectSettings.current.excludedNames);
			project.setSettings(projectSettings);
			configuration.apply(projectSettings.current);
			recentProjects.add(normalized);
			return null;
		}
		return open(path);
	}

	public function add(document:Document):View
		return root.openDocument(documents.add(document));

	public function newDocument():View
		return root.openDocument(documents.createUntitled());

	public function loadPluginManifest(path:String):Bool
		return pluginController.loadManifest(path);

	public function keyPressed(key:Int, modifiers:Int):Bool
		return workbench.keyPressed(key, modifiers);

	public function textInput(text:String):Void
		workbench.textInput(text);

	public function setComposition(text:String, start:Int, length:Int):Void
		workbench.setComposition(text, start, length);

	public function clearComposition():Void
		workbench.clearComposition();

	public function openFileCommandView():Void
		workbench.openFileCommandView();

	public function openCommandView():Void
		workbench.openCommandView();

	public function openCompletionCommandView():Void
		workbench.openCompletionCommandView();

	public function openGoToLine():Void
		workbench.openGoToLine();

	public function openDocumentFind():Void {
		search.openDocumentFind();
	}

	public function openWorkspaceFind():Void {
		search.openWorkspaceFind();
	}

	public function previewWorkspaceReplacement(replacement:String):Bool
		return search.previewWorkspaceReplacement(replacement);

	public function applyWorkspaceReplacement():Bool
		return search.applyWorkspaceReplacement();

	public function replaceCurrent(replacement:String):Bool
		return search.replaceCurrent(replacement);

	public function replaceAll(replacement:String):Int
		return search.replaceAll(replacement);

	function get_replacementPreview():Null<ReplacementPreview>
		return search.replacementPreview;

	function get_replacementResult():Null<ReplacementResult>
		return search.replacementResult;

	function get_documentSearchQuery():String
		return search.documentSearchQuery;

	public function requestCloseActiveTab():Bool
		return files.requestCloseActiveTab();

	public function requestCloseActivePane():Bool
		return files.requestCloseActivePane();

	public function requestQuit():Bool
		return files.requestQuit();

	function get_quitReady():Bool
		return files.quitReady;

	public function openSaveAs(document:Document, ?onSuccess:Void->Void):Void
		files.openSaveAs(document, onSuccess);

	public function openCreateFile():Void
		files.openCreateFile();

	public function openCreateFolder():Void
		files.openCreateFolder();

	public function openRenameFile():Void
		files.openRenameFile();

	public function openDeleteFile():Void
		files.openDeleteFile();

	public function openSettingsCommandView():Void
		configuration.openSettingsCommandView();

	public function openKeybindingsCommandView():Void
		configuration.openKeybindingsCommandView();

	public function openErrorLog():Void
		workbench.openErrorLog();

	public function openRecoveryCommandView():Bool
		return session.openRecoveryCommandView();

	public function update():Void {
		var now = Sys.time();
		configuration.update();
		search.update(now);
		workspace.jobs.update(32);
		session.update(now);
		pluginController.update(now);
		build.update();
		language.update(now);
	}

	function effectiveSettings():Settings
		return configuration.effectiveSettings();

	public function reportInformation(message:String):Void
		root.notifications.publish(message, NotificationKind.Information);

	public function reportError(source:String, message:String):Void {
		errors.record(source, message);
		root.notifications.publish(message, NotificationKind.Error);
	}

	public function shutdown():Void {
		configuration.shutdown();
		pluginController.shutdown();
		build.shutdown();
		language.shutdown();
		processes.shutdown();
		session.shutdown();
	}
}
