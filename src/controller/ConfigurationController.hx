package controller;

import command.CommandContext;
import command.CommandRegistry;
import command.KeyBinding;
import command.Keymap;
import commandview.CommandViewEntry;
import commandview.CommandViewProvider;
import config.Settings;
import config.Preferences;
import core.WorkbenchHost;
import editor.Document;
import platform.Platform;
import style.Theme;
import workspace.Workspace;

class ConfigurationController {
	public final settings:Preferences;

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
	final editorConfig = new config.EditorConfig();

	public function new(settings:Preferences, workspace:Workspace, root:WorkbenchHost, context:CommandContext, commands:CommandRegistry,
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
		var preference = settings, value = settings.current, matchedLength = -1;
		for (project in workspace.projects) {
			var projectSettings = project.settings;
			if (projectSettings != null && document.path != null && StringTools.startsWith(document.path, project.root + "/")
				&& project.root.length > matchedLength) {
				value = projectSettings.current; preference = projectSettings;
				matchedLength = project.root.length;
			}
		}
		var policy = document.indentation;
		var ec:Map<String, String> = document.path == null ? [] : editorConfig.resolve(document.path, document.indentationFileSystem());
		var ecSize = config.EditorConfig.positive(ec.get("indent_size")), ecTab = config.EditorConfig.positive(ec.get("tab_width"));
		var width = policy.detectedWidth == null ? value.tabWidth : policy.detectedWidth;
		var spaces = policy.detectedSpaces == null ? value.insertSpaces : policy.detectedSpaces;
		var widthSource = policy.detectedWidth != null ? "Detected from document" : "Defaults";
		var styleSource = policy.detectedSpaces != null ? "Detected from document" : "Defaults";
		if (ecSize != null || ecTab != null) widthSource = ".editorconfig";
		if (ec.get("indent_style") == "tab" || ec.get("indent_style") == "space") styleSource = ".editorconfig";
		if (ecSize != null) width = ecSize;
		if (ecTab != null) width = ecTab;
		if (ec.get("indent_style") == "tab") spaces = false;
		if (ec.get("indent_style") == "space") spaces = true;
		var step = ecSize == null ? width : ecSize;
		if (preference.explicitlySets("editor/indentation/tab_width")) { width = value.tabWidth; step = width; widthSource = "Configured settings"; }
		if (preference.explicitlySets("editor/indentation/insert_spaces")) { spaces = value.insertSpaces; styleSource = "Configured settings"; }
		if (policy.overrideWidth != null) { width = policy.overrideWidth; step = width; widthSource = "Document override"; }
		if (policy.overrideSpaces != null) { spaces = policy.overrideSpaces; styleSource = "Document override"; }
		var source = widthSource == styleSource ? widthSource : "Width: " + widthSource + "; style: " + styleSource;
		var previous = policy.effective;
		if (policy.base == value && previous != null && previous.tabWidth == width && previous.insertSpaces == spaces && previous.indentSize == step && policy.source == source) return previous;
		var result = value.copy(); result.tabWidth = width; result.insertSpaces = spaces; result.indentSize = step;
		policy.base = value; policy.effective = result; policy.source = source;
		return result;
	}

	public function openWhitespaceCommandView():Void {
		var current = settings.current.renderWhitespace;
		var entries = [
			new CommandViewEntry("Selection", "Show spaces and tabs in selected text", "selection", current == "selection" ? "Current" : ""),
			new CommandViewEntry("All", "Show spaces, tabs, and line endings throughout the document", "all", current == "all" ? "Current" : "")
		];
		root.openCommandView(new CommandViewProvider("Render Whitespace (" + current + "): ", entries, function(_) {}, function(entry, _, _) {
			if (entry == null) return;
			var error = settings.store.set("editor/display/render_whitespace", haxeon.ui.properties.PropertyValue.Enum(entry.value));
			if (error != null) { reportError("configuration", error); return; }
			if (!settings.store.save()) { reportError("configuration", settings.store.lastError); return; }
			root.closeCommandView();
		}));
	}

	public function openIndentationCommandView():Void {
		var document = activeDocument();
		if (document == null) return;
		settingsFor(document);
		var entries:Array<CommandViewEntry> = [];
		entries.push(new CommandViewEntry("Automatic", "Use settings, .editorconfig, then detection", "auto"));
		for (spaces in [true, false]) for (width in 1...17)
			entries.push(new CommandViewEntry((spaces ? "Spaces: " : "Tabs: ") + width, "Use for this document", (spaces ? "spaces:" : "tabs:") + width));
		root.openCommandView(new CommandViewProvider("Indentation (" + document.indentation.source + "): ", entries, function(_) {}, function(entry, query, backwards) {
			if (entry == null) return;
			if (entry.value == "auto") { document.indentation.overrideWidth = null; document.indentation.overrideSpaces = null; }
			else { var parts = entry.value.split(":"); document.indentation.overrideWidth = Std.parseInt(parts[1]); document.indentation.overrideSpaces = parts[0] == "spaces"; }
			settingsFor(document); root.closeCommandView();
		}));
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
		for (project in workspace.projects) { var local = project.settings; if (local != null) local.reload(); }
		var effective = effectiveSettings();
		if (effective != appliedSettings) apply(effective);
		reportDiagnostics();
	}

	public function openSettingsCommandView():Void {
		var value = effectiveSettings(), entries = [
			new CommandViewEntry("editor.fontPath", value.fontPath, "editor.fontPath"),
			new CommandViewEntry("editor.renderWhitespace", value.renderWhitespace, "editor.renderWhitespace"),
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
		commands.add("settings:reload", function(context) { settings.reload(true); editorConfig.invalidate(); });
		commands.add("doc:render-whitespace", _ -> openWhitespaceCommandView(), hasDocument, "Editor: Render Whitespace");
		commands.add("doc:toggle-render-whitespace", _ -> {
			var mode = settings.current.renderWhitespace == "all" ? "selection" : "all";
			var error = settings.store.set("editor/display/render_whitespace", haxeon.ui.properties.PropertyValue.Enum(mode));
			if (error != null) reportError("configuration", error);
			else if (!settings.store.save()) reportError("configuration", settings.store.lastError);
			root.selectionChanged();
		}, hasDocument, "Editor: Toggle Render Whitespace");
		commands.add("doc:indentation", context -> openIndentationCommandView(), hasDocument, "Choose Document Indentation");
		for (whole in [false, true]) {
			var entire = whole;
			commands.addEditorAction(entire ? "doc:reindent-document" : "doc:reindent-selection", function(context) {
				var document = context.requireDocument(), selection = context.requireView().getSelection(), value = settingsFor(document);
				if (selection != null) editor.EditorActions.reindent(document.buffer, selection, document.highlighter, value.tabWidth, value.insertSpaces, value.indentSize, entire);
			}, function(context) return hasDocument(context) && context.requireDocument().syntax.name == "Haxe", entire ? "Reindent Document" : "Reindent Selection");
		}
		commands.add("settings:open", context -> openSettingsCommandView());
		commands.add("keybindings:open", context -> openKeybindingsCommandView());
		commands.addEditorAction("doc:tab", function(context) {
			var value = settingsFor(context.requireDocument());
			context.requireView().tab(value.tabWidth, value.insertSpaces, value.indentSize);
		}, hasDocument);
		commands.addEditorAction("doc:backspace", function(context) {
			context.requireView().backspace(settingsFor(context.requireDocument()).tabWidth, settingsFor(context.requireDocument()).indentSize);
		}, hasDocument);
		commands.addEditorAction("doc:newline", function(context) {
			var value = settingsFor(context.requireDocument());
			context.requireView().insertNewline(value.tabWidth, value.insertSpaces, value.indentSize);
		}, hasDocument);
		commands.addEditorAction("doc:indent", function(context) {
			var value = settingsFor(context.requireDocument());
			context.requireView().indent(value.tabWidth, value.insertSpaces, value.indentSize);
		}, hasDocument);
		commands.addEditorAction("doc:unindent", function(context) {
			var value = settingsFor(context.requireDocument());
			context.requireView().unindent(value.tabWidth, value.indentSize);
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
