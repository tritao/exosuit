package controller;

import command.CommandContext;
import command.CommandRegistry;
import command.KeyBinding;
import command.Keymap;
import commandview.CommandViewEntry;
import commandview.CommandViewProvider;
import config.Settings;
import config.SettingsService;
import core.WorkbenchHost;
import editor.Document;
import platform.Platform;
import style.Theme;
import workspace.Workspace;

class ConfigurationController {
	public final settings:SettingsService;

	final workspace:Workspace;
	final root:WorkbenchHost;
	final context:CommandContext;
	final keymap:Keymap;
	final theme:Theme;
	final search:SearchController;
	final reportError:(String, String)->Void;
	final releaseSettings:Void->Void;
	var appliedSettings:Null<Settings>;
	var lastDiagnostics:String = "";

	public function new(settings:SettingsService, workspace:Workspace, root:WorkbenchHost, context:CommandContext, commands:CommandRegistry,
		keymap:Keymap, theme:Theme, search:SearchController, reportError:(String, String)->Void) {
		this.settings = settings;
		this.workspace = workspace;
		this.root = root;
		this.context = context;
		this.keymap = keymap;
		this.theme = theme;
		this.search = search;
		this.reportError = reportError;
		installCommands(commands);
		releaseSettings = settings.subscribe(apply);
	}

	public function effectiveSettings():Settings {
		var document = activeDocument();
		if (document != null) return settingsFor(document);
		var project = workspace.activeProject;
		if (project == null) return settings.current;
		var projectSettings = project.settings;
		return projectSettings == null ? settings.current : projectSettings.current;
	}

	public function settingsFor(document:Document):Settings {
		var value = settings.current, matchedLength = -1;
		for (project in workspace.projects) {
			var projectSettings = project.settings;
			if (projectSettings != null && document.path != null && StringTools.startsWith(document.path, project.root + "/")
				&& project.root.length > matchedLength) {
				value = projectSettings.current;
				matchedLength = project.root.length;
			}
		}
		return value;
	}

	public function apply(value:Settings):Void {
		appliedSettings = value;
		theme.editorBackground = value.editorBackground;
		theme.editorForeground = value.editorForeground;
		theme.accent = value.accent;
		theme.surface = value.surface;
		theme.surfaceElevated = value.surfaceElevated;
		theme.surfaceActive = value.surfaceActive;
		theme.surfaceInactive = value.surfaceInactive;
		theme.surfaceHover = value.surfaceHover;
		theme.border = value.border;
		theme.divider = value.divider;
		theme.foregroundMuted = value.foregroundMuted;
		theme.foregroundSubtle = value.foregroundSubtle;
		theme.foregroundDisabled = value.foregroundDisabled;
		theme.selection = value.selection;
		theme.searchMatch = value.searchMatch;
		theme.caret = value.caret;
		theme.overlay = value.overlay;
		theme.information = value.information;
		theme.warning = value.warning;
		theme.error = value.error;
		theme.scrollbar = value.scrollbar;
		search.applySettings(value);
		keymap.setConfigured([for (binding in value.keybindings) new KeyBinding(binding.key, binding.modifiers, binding.commands)]);
		if (!root.applySettings(value)) {
			var diagnostic = 'could not load font "' + value.fontPath + '"';
			settings.diagnostics.push(diagnostic);
			reportError("configuration", diagnostic);
		}
	}

	public function update():Void {
		settings.reload();
		var effective = effectiveSettings();
		if (effective != appliedSettings) apply(effective);
		reportDiagnostics();
	}

	public function openSettingsCommandView():Void {
		var value = effectiveSettings(), entries = [
			new CommandViewEntry("editor.fontPath", value.fontPath, "editor.fontPath"),
			new CommandViewEntry("editor.fontSize", Std.string(value.fontSize), "editor.fontSize"),
			new CommandViewEntry("editor.tabWidth", Std.string(value.tabWidth), "editor.tabWidth"),
			new CommandViewEntry("editor.insertSpaces", Std.string(value.insertSpaces), "editor.insertSpaces"),
			new CommandViewEntry("editor.scroll_animation_type", value.scrollAnimationType, "editor.scroll_animation_type"),
			new CommandViewEntry("editor.scroll_animation_duration", Std.string(value.scrollAnimationDuration), "editor.scroll_animation_duration"),
			new CommandViewEntry("plugins.haxeon.enabled", Std.string(value.haxeonEnabled), "plugins.haxeon.enabled"),
			new CommandViewEntry("plugins.haxeon.command", haxe.Json.stringify(value.haxeonCommand), "plugins.haxeon.command"),
			new CommandViewEntry("plugins.haxeon.verbose", Std.string(value.haxeonVerbose), "plugins.haxeon.verbose"),
			new CommandViewEntry("workbench.sidebarWidth", Std.string(value.sidebarWidth), "workbench.sidebarWidth"),
			new CommandViewEntry("files.exclude", value.excludedNames.join(","), "files.exclude"),
			new CommandViewEntry("search.caseSensitive", Std.string(value.searchCaseSensitive), "search.caseSensitive"),
			new CommandViewEntry("search.wholeWord", Std.string(value.searchWholeWord), "search.wholeWord"),
			new CommandViewEntry("search.maxResults", Std.string(value.searchMaxResults), "search.maxResults"),
			new CommandViewEntry("theme.editorBackground", Std.string(value.editorBackground), "theme.editorBackground"),
			new CommandViewEntry("theme.editorForeground", Std.string(value.editorForeground), "theme.editorForeground"),
			new CommandViewEntry("theme.accent", Std.string(value.accent), "theme.accent"),
			new CommandViewEntry("theme.surface", Std.string(value.surface), "theme.surface"),
			new CommandViewEntry("theme.selection", Std.string(value.selection), "theme.selection"),
			new CommandViewEntry("theme.searchMatch", Std.string(value.searchMatch), "theme.searchMatch"),
			new CommandViewEntry("theme.caret", Std.string(value.caret), "theme.caret")
		];
		for (diagnostic in settings.diagnostics)
			entries.unshift(new CommandViewEntry("Configuration error", diagnostic, diagnostic));
		var project = workspace.activeProject, projectSettings = project == null ? null : project.settings;
		if (projectSettings != null)
			for (diagnostic in projectSettings.diagnostics)
				entries.unshift(new CommandViewEntry("Configuration error", diagnostic, diagnostic));
		root.openCommandView(new CommandViewProvider("Settings: ", entries, function(query) {}, function(entry, query, backwards) {
			root.closeCommandView();
		}));
	}

	public function openKeybindingsCommandView():Void {
		var entries:Array<CommandViewEntry> = [];
		for (binding in effectiveSettings().keybindings)
			entries.push(new CommandViewEntry(new command.KeyBinding(binding.key, binding.modifiers, []).displayName(),
				binding.commands.join(", "), binding.commands[0]));
		root.openCommandView(new CommandViewProvider("Keybindings: ", entries, function(query) {}, function(entry, query, backwards) {
			root.closeCommandView();
		}));
	}

	public function shutdown():Void
		releaseSettings();

	function installCommands(commands:CommandRegistry):Void {
		commands.add("settings:reload", context -> settings.reload(true));
		commands.add("settings:open", context -> openSettingsCommandView());
		commands.add("keybindings:open", context -> openKeybindingsCommandView());
		commands.add("doc:indent", function(context) {
			var value = settingsFor(context.requireDocument());
			context.requireView().indent(value.tabWidth, value.insertSpaces);
		}, hasDocument);
		commands.add("doc:unindent", function(context) {
			var value = settingsFor(context.requireDocument());
			context.requireView().unindent(value.tabWidth);
		}, hasDocument);
	}

	function hasDocument(context:CommandContext):Bool
		return context.activeView() != null && context.activeView().getDocument() != null;

	function activeDocument():Null<Document> {
		var view = context.activeView();
		return view == null ? null : view.getDocument();
	}

	function reportDiagnostics():Void {
		var values = settings.diagnostics.copy();
		for (project in workspace.projects) {
			var projectSettings = project.settings;
			if (projectSettings != null)
				for (diagnostic in projectSettings.diagnostics) values.push(diagnostic);
		}
		var identity = values.join("\n");
		if (identity == lastDiagnostics) return;
		lastDiagnostics = identity;
		for (diagnostic in values) reportError("configuration", diagnostic);
	}

}
