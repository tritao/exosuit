package core;

import platform.HostCapabilities;
import platform.HostCapability;
import command.CommandContext;
import command.CommandRegistry;
import command.EditorCommands;
import command.Keymap;
import core.FileActions;
import core.WelcomeActions;
import core.WorkbenchHost;
import editor.Document;
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
import config.Preferences;
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
import platform.Platform;
import session.RecentProjects;

class Application {
	public final capabilities:HostCapabilities;
	public final documents:DocumentManager;
	public final workspace:Workspace;
	public final fileOperations:FileOperations;
	public final focus:FocusManager;
	public final root:WorkbenchHost;
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
	public final settings:Preferences;
	public final recovery:RecoveryStore;
	public final errors:ErrorLog;
	public final confirmations:ConfirmationService;
	public final recentProjects:RecentProjects;
	public final documentMatches:Array<SearchMatch>;
	public var documentSearchQuery(get, never):String;
	public var quitReady(get, never):Bool;

	public function new(hostFactory:(theme:Theme, focus:FocusManager, workspace:Workspace, settings:Settings)->WorkbenchHost,
			?settings:Preferences, ?recentProjects:RecentProjects, ?capabilities:HostCapabilities) {
		this.capabilities = capabilities == null ? HostCapabilities.desktop() : capabilities;
		this.settings = settings == null ? new Preferences() : settings;
		syntaxes = new SyntaxRegistry();
		BuiltinSyntax.install(syntaxes);
		completions = new CompletionRegistry();
		completions.add("core", new DocumentWordCompletionProvider());
		theme = new Theme();
		workspace = new Workspace(syntaxes);
		processes = new ProcessManager(this.capabilities.supports(Processes));
		fileOperations = new FileOperations(workspace, new TrashService(ConfigurationPaths.trash(), workspace.fileSystem));
		documents = workspace.documents;
		focus = new FocusManager();
		root = hostFactory(theme, focus, workspace, this.settings.current);
		errors = new ErrorLog();
		confirmations = new ConfirmationService(root);
		this.recentProjects = recentProjects == null ? new RecentProjects(ConfigurationPaths.recentProjects()) : recentProjects;
		commands = new CommandRegistry();
		keymap = new Keymap(commands);
		context = new CommandContext(root, focus, documents);
		EditorCommands.install(commands, keymap, this.capabilities.supports(Clipboard));
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
		pluginController = new PluginController(commands, keymap, context, syntaxes, completions, root.getPluginPanels(), workspace.jobs,
			effectiveSettings, root, processes, reportError, reportInformation, this.capabilities.supports(SourcePlugins));
		plugins = pluginController.manager;
		workbench = new WorkbenchController(workspace, root, commands, keymap, context, completions, errors, search,
			path -> { open(path); });
		workbench.openPath = function(path) { openArgument(path); };
		build = new BuildController(workspace, root, context, commands, processes, path -> open(path), reportError, this.capabilities.supports(Processes));
		var languageCommand = config.LanguageServerCommand.current(this.settings.current);
		language = new LanguageController(workspace, root, context, commands, processes, languageCommand[0], reportError,
			languageCommand.slice(1), this.capabilities.supports(LanguageServices), () -> this.settings.current);
		language.documentSettings = configuration.settingsFor;
		keymap.add(Platform.KEY_G, Platform.MOD_CTRL | Platform.MOD_SHIFT, ["language:document-symbols"]);
		keymap.add(Platform.KEY_H, Platform.MOD_CTRL | Platform.MOD_SHIFT, ["language:find-references"]);
		keymap.add(Platform.KEY_H, Platform.MOD_CTRL | Platform.MOD_ALT, ["language:rename-symbol"]);
		keymap.add(Platform.KEY_SPACE, Platform.MOD_CTRL, ["language:complete"]);
		keymap.add(Platform.KEY_SPACE, Platform.MOD_CTRL | Platform.MOD_ALT, ["language:hover"]);
		keymap.add(Platform.KEY_SPACE, Platform.MOD_CTRL | Platform.MOD_SHIFT, ["language:signature-help"]);
		keymap.add(Platform.KEY_G, Platform.MOD_CTRL | Platform.MOD_ALT, ["language:go-to-definition"]);

		root.configureWelcomeActions({
			recentProjects: this.recentProjects.paths,
			newFile: function() { newDocument(); },
			openFile: function() { workbench.openPathCommandView(false); },
			openProject: function() { workbench.openPathCommandView(true); },
			findFile: function() { workbench.openFileCommandView(); },
			runCommand: function() { workbench.openCommandView(); },
			openSettings: function() { configuration.openSettingsCommandView(); },
			openPlugins: function() { pluginController.openDiagnostics(); },
			openRecent: function(path) { openArgument(path); }
		});
		root.configureFileActions({
			createFile: function() { files.openCreateFile(); },
			createFolder: function() { files.openCreateFolder(); },
			renameFile: function() { files.openRenameFile(); },
			deleteFile: function() { files.openDeleteFile(); },
			closeTab: function() { requestCloseActiveTab(); }
		});
	}

	/** Optional host file opener; null falls back to a text document. */
	public var openFileView:Null<(String, Bool)->Null<View>>;

	public function open(path:String, preview:Bool = false):View {
		if (openFileView != null) {
			var resource = openFileView(path, preview);
			if (resource != null) return resource;
		}
		return root.openDocument(documents.open(path));
	}

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
		root.getNotifications().publish(message, NotificationKind.Information);

	public function reportError(source:String, message:String):Void {
		errors.record(source, message);
		root.getNotifications().publish(message, NotificationKind.Error, source);
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
