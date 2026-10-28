package config;

import haxeon.ui.settings.SettingsRegistry;
import haxeon.ui.settings.SettingOptions;
import haxeon.ui.settings.SettingsStore;
import haxeon.ui.settings.SettingDefinition;
import platform.Platform;
import haxeon.ui.properties.PropertyType;
import haxeon.ui.properties.PropertyValue;
import haxeon.ui.properties.PropertyOption;

/** Exosuit definitions and typed snapshots over UIKit settings. */
class PreferencesRegistry {
	public static function create(projectOnly:Bool = false):SettingsRegistry {
		var registry = new SettingsRegistry(), defaults = new Settings();
		if (!projectOnly) registry.define("files/explorer/confirm_trash", PropertyType.Bool, PropertyValue.Bool(defaults.confirmTrash));
		{
			var options = new SettingOptions();
			options.restartRequired = true;
			if (!projectOnly) registry.define("editor/fonts/font_path", PropertyType.Text, PropertyValue.Text(defaults.fontPath), options);
		}
		{
			var options = new SettingOptions();
			options.advanced = true; options.tooltip = "JSON array; changes apply when the value is valid.";
			options.restartRequired = true;
			if (!projectOnly) registry.add(new ArraySettingDefinition("editor/fonts/font_fallback_paths", PropertyType.Text, PropertyValue.Text(haxe.Json.stringify(defaults.fontFallbackPaths)), options));
		}
		{
			var options = new SettingOptions();
			options.minimum = 6; options.maximum = 96;
			options.unit = "px";
			if (!projectOnly) registry.define("editor/fonts/font_size", PropertyType.Int, PropertyValue.Int(defaults.fontSize), options);
		}
		{
			var options = new SettingOptions();
			options.minimum = 6; options.maximum = 96;
			options.tooltip = "File tree text size, independent of editor font size.";
			options.unit = "px";
			if (!projectOnly) registry.define("files/explorer/font_size", PropertyType.Int, PropertyValue.Int(defaults.explorerFontSize), options);
		}
		{
			var options = new SettingOptions();
			options.minimum = 70; options.maximum = 200; options.step = 10;
			options.tooltip = "Scale the whole application independently of editor font size.";
			options.unit = "%";
			if (!projectOnly) registry.define("appearance/workbench/zoom_percent", PropertyType.Int, PropertyValue.Int(defaults.applicationZoom), options);
		}
		{
			var options = new SettingOptions();
			options.options = [new PropertyOption("auto", "Automatic"), new PropertyOption("editor", "Editor"), new PropertyOption("agents", "Agents")];
			options.tooltip = "Default layout mode. Automatic uses Agents when a Workbench service with groups is connected. A window can choose a different mode from Layout.";
			if (!projectOnly) registry.define("appearance/workbench/layout_mode", PropertyType.Enum, PropertyValue.Enum(defaults.layoutMode), options);
		}
		{
			var options = new SettingOptions();
			// Changed from the Activity Bar itself, like VS Code, so every window and folder keeps the same rail.
			options.internal = true;
			if (!projectOnly) registry.define("appearance/workbench/activity_bar", PropertyType.Text, PropertyValue.Text(defaults.activityBar), options);
		}
		{
			var options = new SettingOptions();
			options.minimum = 100; options.maximum = 1200;
			options.unit = "px";
			if (!projectOnly) registry.define("appearance/workbench/sidebar_width", PropertyType.Int, PropertyValue.Int(defaults.sidebarWidth), options);
		}
		{
			var options = new SettingOptions();
			// The settings dialog renders this persisted value with the live Codex model picker.
			options.tooltip = "Model for new Workbench Codex sessions. Existing sessions keep their selected model.";
			if (!projectOnly) registry.define("workbench/codex/default_model", PropertyType.Text, PropertyValue.Text(defaults.codexDefaultModel), options);
		}
		{
			var options = new SettingOptions();
			options.tooltip = "Reasoning effort for new Workbench Codex sessions.";
			options.options = [
				new PropertyOption("model-default", "Model default"),
				new PropertyOption("none", "None"),
				new PropertyOption("minimal", "Minimal"),
				new PropertyOption("low", "Low"),
				new PropertyOption("medium", "Medium"),
				new PropertyOption("high", "High"),
				new PropertyOption("xhigh", "Extra high"),
				new PropertyOption("max", "Maximum")
			];
			if (!projectOnly) registry.define("workbench/codex/default_effort", PropertyType.Enum, PropertyValue.Enum(defaults.codexDefaultEffort), options);
		}
		{
			var options = new SettingOptions();
			options.tooltip = "Permission preset for new Workbench Codex sessions. Full access skips approval prompts; existing sessions keep their selected preset.";
			options.advanced = true;
			options.options = [
				new PropertyOption("read-only", "Read-only"),
				new PropertyOption("workspace-write", "Workspace access"),
				new PropertyOption("full-access", "Full access")
			];
			if (!projectOnly) registry.define("workbench/codex/default_permissions", PropertyType.Enum, PropertyValue.Enum(defaults.codexDefaultPermissions), options);
		}
		{
			var options = new SettingOptions();
			options.options = [new PropertyOption("auto", "Auto"), new PropertyOption("always", "Always"), new PropertyOption("hidden", "Hidden")];
			if (!projectOnly) registry.define("editor/display/scrollbar_visibility", PropertyType.Enum, PropertyValue.Enum(defaults.scrollbarVisibility), options);
		}
		{
			var options = new SettingOptions();
			if (!projectOnly) registry.define("editor/display/minimap_enabled", PropertyType.Bool, PropertyValue.Bool(defaults.minimapEnabled), options);
			if (!projectOnly) registry.define("editor/display/word_wrap", PropertyType.Bool, PropertyValue.Bool(defaults.wordWrap), options);
		}
		{
			var options = new SettingOptions();
			options.options = [new PropertyOption("selection", "Selection"), new PropertyOption("all", "All")];
			if (!projectOnly) registry.define("editor/display/render_whitespace", PropertyType.Enum, PropertyValue.Enum(defaults.renderWhitespace), options);
		}
		{
			var options = new SettingOptions();
			options.minimum = 0; options.maximum = 5;
			options.unit = "seconds";
			if (!projectOnly) registry.define("editor/display/tab_tooltip_delay", PropertyType.Float, PropertyValue.Float(defaults.tabTooltipDelay), options);
		}

		{
			var options = new SettingOptions();
			options.minimum = 1; options.maximum = 16;
			options.preserveExplicitDefault = true;
			options.unit = "columns";
			registry.define("editor/indentation/tab_width", PropertyType.Int, PropertyValue.Int(defaults.tabWidth), options);
		}
		{
			var options = new SettingOptions();
			options.preserveExplicitDefault = true;
			registry.define("editor/indentation/insert_spaces", PropertyType.Bool, PropertyValue.Bool(defaults.insertSpaces), options);
		}
		{
			var options = new SettingOptions();
			options.options = [new PropertyOption("smooth", "Smooth"), new PropertyOption("none", "None")];
			if (!projectOnly) registry.define("editor/display/scroll_animation_type", PropertyType.Enum, PropertyValue.Enum(defaults.scrollAnimationType), options);
		}
		{
			var options = new SettingOptions();
			options.minimum = 0; options.maximum = 0.3;
			options.unit = "seconds";
			if (!projectOnly) registry.define("editor/display/scroll_animation_duration", PropertyType.Float, PropertyValue.Float(defaults.scrollAnimationDuration), options);
		}
		{
			var options = new SettingOptions();
			registry.define("languages/haxeon/enabled", PropertyType.Bool, PropertyValue.Bool(defaults.haxeonEnabled), options);
		}
		{
			var options = new SettingOptions();
			options.advanced = true; options.tooltip = "JSON array; changes apply when the value is valid.";
			registry.add(new ArraySettingDefinition("languages/haxeon/command", PropertyType.Text, PropertyValue.Text(haxe.Json.stringify(defaults.haxeonCommand)), options));
		}
		{
			var options = new SettingOptions();
			registry.define("languages/haxeon/verbose", PropertyType.Bool, PropertyValue.Bool(defaults.haxeonVerbose), options);
		}
		{
			var options = new SettingOptions();
			options.advanced = true; options.tooltip = "JSON array; changes apply when the value is valid.";
			registry.add(new ArraySettingDefinition("files/explorer/excluded_names", PropertyType.Text, PropertyValue.Text(haxe.Json.stringify(defaults.excludedNames)), options));
		}
		{
			var options = new SettingOptions();
			options.tooltip = "Enable Git source control for open workspace roots.";
			if (!projectOnly) registry.define("scm/enabled", PropertyType.Bool, PropertyValue.Bool(defaults.scmEnabled), options);
		}
		{
			var options = new SettingOptions();
			options.advanced = true; options.tooltip = "Optional path to Git; empty uses PATH.";
			if (!projectOnly) registry.define("scm/git_path", PropertyType.Text, PropertyValue.Text(defaults.scmGitPath), options);
		}
		{
			var options = new SettingOptions();
			options.minimum = 0; options.maximum = 1000000;
			options.tooltip = "Maximum untracked resources shown per repository.";
			options.unit = "files";
			if (!projectOnly) registry.define("scm/untracked_limit", PropertyType.Int, PropertyValue.Int(defaults.scmUntrackedLimit), options);
		}
		{
			var options = new SettingOptions();
			options.minimum = 1024; options.maximum = 67108864;
			options.tooltip = "Maximum bytes loaded for a source control diff.";
			options.unit = "bytes";
			if (!projectOnly) registry.define("scm/diff_size_limit", PropertyType.Int, PropertyValue.Int(defaults.scmDiffSizeLimit), options);
		}
		{
			var options = new SettingOptions();
			options.minimum = 0; options.maximum = 8;
			options.tooltip = "Maximum nested repository scan depth.";
			options.unit = "levels";
			if (!projectOnly) registry.define("scm/nested_scan_depth", PropertyType.Int, PropertyValue.Int(defaults.scmNestedScanDepth), options);
		}
		{
			var options = new SettingOptions();
			if (!projectOnly) registry.define("scm/auto_refresh", PropertyType.Bool, PropertyValue.Bool(defaults.scmAutoRefresh), options);
		}
		{
			var options = new SettingOptions();
			options.tooltip = "Fetch remote updates periodically while source control is open. Disabled by default.";
			if (!projectOnly) registry.define("scm/auto_fetch", PropertyType.Bool, PropertyValue.Bool(defaults.scmAutoFetch), options);
		}
		{
			var options = new SettingOptions();
			options.tooltip = "Offer Commit All when there are no staged changes.";
			if (!projectOnly) registry.define("scm/commit_all_when_nothing_staged", PropertyType.Bool,
				PropertyValue.Bool(defaults.scmCommitAllWhenNothingStaged), options);
		}
		{
			var options = new SettingOptions();
			options.tooltip = "Show source control change markers beside editor line numbers.";
			if (!projectOnly) registry.define("scm/gutter", PropertyType.Bool, PropertyValue.Bool(defaults.scmGutter), options);
		}
		{
			var options = new SettingOptions();
			options.tooltip = "Show source control badges in the file tree.";
			if (!projectOnly) registry.define("scm/explorer_decorations", PropertyType.Bool, PropertyValue.Bool(defaults.scmExplorerDecorations), options);
		}
		{
			var options = new SettingOptions();
			if (!projectOnly) registry.define("search/results/case_sensitive", PropertyType.Bool, PropertyValue.Bool(defaults.searchCaseSensitive), options);
		}
		{
			var options = new SettingOptions();
			if (!projectOnly) registry.define("search/results/whole_word", PropertyType.Bool, PropertyValue.Bool(defaults.searchWholeWord), options);
		}
		{
			var options = new SettingOptions();
			options.minimum = 1; options.maximum = 1000000;
			options.unit = "results";
			if (!projectOnly) registry.define("search/results/max_results", PropertyType.Int, PropertyValue.Int(defaults.searchMaxResults), options);
		}
		{
			var options = new SettingOptions();
			options.advanced = true; options.tooltip = "Signed RGBA integer.";
			if (!projectOnly) registry.define("appearance/colors/editor_background", PropertyType.Int, PropertyValue.Int(defaults.editorBackground), options);
		}
		{
			var options = new SettingOptions();
			options.advanced = true; options.tooltip = "Signed RGBA integer.";
			if (!projectOnly) registry.define("appearance/colors/editor_foreground", PropertyType.Int, PropertyValue.Int(defaults.editorForeground), options);
		}
		{
			var options = new SettingOptions();
			options.advanced = true; options.tooltip = "Signed RGBA integer.";
			if (!projectOnly) registry.define("appearance/colors/accent", PropertyType.Int, PropertyValue.Int(defaults.accent), options);
		}
		{
			var options = new SettingOptions();
			options.advanced = true; options.tooltip = "Signed RGBA integer.";
			if (!projectOnly) registry.define("appearance/colors/surface", PropertyType.Int, PropertyValue.Int(defaults.surface), options);
		}
		{
			var options = new SettingOptions();
			options.advanced = true; options.tooltip = "Signed RGBA integer.";
			if (!projectOnly) registry.define("appearance/colors/surface_elevated", PropertyType.Int, PropertyValue.Int(defaults.surfaceElevated), options);
		}
		{
			var options = new SettingOptions();
			options.advanced = true; options.tooltip = "Signed RGBA integer.";
			if (!projectOnly) registry.define("appearance/colors/surface_active", PropertyType.Int, PropertyValue.Int(defaults.surfaceActive), options);
		}
		{
			var options = new SettingOptions();
			options.advanced = true; options.tooltip = "Signed RGBA integer.";
			if (!projectOnly) registry.define("appearance/colors/surface_inactive", PropertyType.Int, PropertyValue.Int(defaults.surfaceInactive), options);
		}
		{
			var options = new SettingOptions();
			options.advanced = true; options.tooltip = "Signed RGBA integer.";
			if (!projectOnly) registry.define("appearance/colors/surface_hover", PropertyType.Int, PropertyValue.Int(defaults.surfaceHover), options);
		}
		{
			var options = new SettingOptions();
			options.advanced = true; options.tooltip = "Signed RGBA integer.";
			if (!projectOnly) registry.define("appearance/colors/border", PropertyType.Int, PropertyValue.Int(defaults.border), options);
		}
		{
			var options = new SettingOptions();
			options.advanced = true; options.tooltip = "Signed RGBA integer.";
			if (!projectOnly) registry.define("appearance/colors/divider", PropertyType.Int, PropertyValue.Int(defaults.divider), options);
		}
		{
			var options = new SettingOptions();
			options.advanced = true; options.tooltip = "Signed RGBA integer.";
			if (!projectOnly) registry.define("appearance/colors/foreground_muted", PropertyType.Int, PropertyValue.Int(defaults.foregroundMuted), options);
		}
		{
			var options = new SettingOptions();
			options.advanced = true; options.tooltip = "Signed RGBA integer.";
			if (!projectOnly) registry.define("appearance/colors/foreground_subtle", PropertyType.Int, PropertyValue.Int(defaults.foregroundSubtle), options);
		}
		{
			var options = new SettingOptions();
			options.advanced = true; options.tooltip = "Signed RGBA integer.";
			if (!projectOnly) registry.define("appearance/colors/foreground_disabled", PropertyType.Int, PropertyValue.Int(defaults.foregroundDisabled), options);
		}
		{
			var options = new SettingOptions();
			options.advanced = true; options.tooltip = "Signed RGBA integer.";
			if (!projectOnly) registry.define("appearance/colors/selection", PropertyType.Int, PropertyValue.Int(defaults.selection), options);
		}
		{
			var options = new SettingOptions();
			options.advanced = true; options.tooltip = "Signed RGBA integer.";
			if (!projectOnly) registry.define("appearance/colors/search_match", PropertyType.Int, PropertyValue.Int(defaults.searchMatch), options);
		}
		{
			var options = new SettingOptions();
			options.advanced = true; options.tooltip = "Signed RGBA integer.";
			if (!projectOnly) registry.define("appearance/colors/caret", PropertyType.Int, PropertyValue.Int(defaults.caret), options);
		}
		{
			var options = new SettingOptions();
			options.advanced = true; options.tooltip = "Signed RGBA integer.";
			if (!projectOnly) registry.define("appearance/colors/overlay", PropertyType.Int, PropertyValue.Int(defaults.overlay), options);
		}
		{
			var options = new SettingOptions();
			options.advanced = true; options.tooltip = "Signed RGBA integer.";
			if (!projectOnly) registry.define("appearance/colors/information", PropertyType.Int, PropertyValue.Int(defaults.information), options);
		}
		{
			var options = new SettingOptions();
			options.advanced = true; options.tooltip = "Signed RGBA integer.";
			if (!projectOnly) registry.define("appearance/colors/warning", PropertyType.Int, PropertyValue.Int(defaults.warning), options);
		}
		{
			var options = new SettingOptions();
			options.advanced = true; options.tooltip = "Signed RGBA integer.";
			if (!projectOnly) registry.define("appearance/colors/error", PropertyType.Int, PropertyValue.Int(defaults.error), options);
		}
		{
			var options = new SettingOptions();
			options.advanced = true; options.tooltip = "Signed RGBA integer.";
			if (!projectOnly) registry.define("appearance/colors/scrollbar", PropertyType.Int, PropertyValue.Int(defaults.scrollbar), options);
		}
		{
			var options = new SettingOptions();
			options.advanced = true; options.tooltip = "JSON array; changes apply when the value is valid.";
			if (!projectOnly) registry.add(new ArraySettingDefinition("editor/keyboard/keybindings", PropertyType.Text, PropertyValue.Text("[]"), options));
		}
		if (!projectOnly) {
			var options = new SettingOptions();
			options.tooltip = "Command IDs whose shortcuts run in the application while a terminal is focused. Add IDs to the defaults, or prefix an ID with '-' to send its keys to the terminal. Domain IDs may omit 'exosuit.'.";
			registry.add(new ArraySettingDefinition("terminal/keyboard/commands_to_skip_shell", PropertyType.Text,
				PropertyValue.Text(haxe.Json.stringify(defaults.terminalCommandsToSkipShell)), options));
		}
		if (!projectOnly) {
			var options = new SettingOptions();
			options.minimum = 6; options.maximum = 48;
			options.unit = "px";
			registry.define("terminal/fonts/font_size", PropertyType.Int, PropertyValue.Int(defaults.terminalFontSize), options);
		}
		if (!projectOnly) {
			var options = new SettingOptions();
			options.label = "Agent session mode";
			options.options = [new PropertyOption("integrated", "Integrated"), new PropertyOption("terminal", "Terminal")];
			options.tooltip = "How new Codex, Claude Code and Pi sessions open. Integrated uses Exosuit's structured interface. Terminal runs the interactive CLI with its own model and approval settings. Existing sessions keep their mode.";
			registry.define("workbench/agents/session_mode", PropertyType.Enum, PropertyValue.Enum(defaults.agentSessionMode), options);
		}
		return registry;
	}

	public static function snapshot(store:SettingsStore, ?base:Settings):Settings {
		var value = base == null ? new Settings() : base.copy();
		if (store.registry.exists("workbench/agents/session_mode") && (base == null || !store.isDefault("workbench/agents/session_mode"))) value.agentSessionMode = store.getString("workbench/agents/session_mode");
		if (store.registry.exists("appearance/workbench/zoom_percent") && (base == null || !store.isDefault("appearance/workbench/zoom_percent"))) value.applicationZoom = store.getInt("appearance/workbench/zoom_percent");
		if (store.registry.exists("appearance/workbench/layout_mode") && (base == null || !store.isDefault("appearance/workbench/layout_mode"))) value.layoutMode = store.getString("appearance/workbench/layout_mode");
		if (store.registry.exists("appearance/workbench/activity_bar") && (base == null || !store.isDefault("appearance/workbench/activity_bar"))) value.activityBar = store.getString("appearance/workbench/activity_bar");
		if (store.registry.exists("workbench/codex/default_model") && (base == null || !store.isDefault("workbench/codex/default_model"))) value.codexDefaultModel = store.getString("workbench/codex/default_model");
		if (store.registry.exists("workbench/codex/default_effort") && (base == null || !store.isDefault("workbench/codex/default_effort"))) value.codexDefaultEffort = store.getString("workbench/codex/default_effort");
		if (store.registry.exists("workbench/codex/default_permissions") && (base == null || !store.isDefault("workbench/codex/default_permissions"))) value.codexDefaultPermissions = store.getString("workbench/codex/default_permissions");
		if (store.registry.exists("editor/fonts/font_path") && (base == null || !store.isDefault("editor/fonts/font_path"))) value.fontPath = store.getString("editor/fonts/font_path");
		if (store.registry.exists("editor/fonts/font_fallback_paths") && (base == null || !store.isDefault("editor/fonts/font_fallback_paths"))) value.fontFallbackPaths = strings(store.getString("editor/fonts/font_fallback_paths"));
		if (store.registry.exists("editor/fonts/font_size") && (base == null || !store.isDefault("editor/fonts/font_size"))) value.fontSize = store.getInt("editor/fonts/font_size");
		if (store.registry.exists("files/explorer/font_size") && (base == null || !store.isDefault("files/explorer/font_size"))) value.explorerFontSize = store.getInt("files/explorer/font_size");
		if (store.registry.exists("files/explorer/confirm_trash") && (base == null || !store.isDefault("files/explorer/confirm_trash"))) value.confirmTrash = store.getBool("files/explorer/confirm_trash");
		if (store.registry.exists("appearance/workbench/sidebar_width") && (base == null || !store.isDefault("appearance/workbench/sidebar_width"))) value.sidebarWidth = store.getInt("appearance/workbench/sidebar_width");
		if (store.registry.exists("editor/display/scrollbar_visibility") && (base == null || !store.isDefault("editor/display/scrollbar_visibility"))) value.scrollbarVisibility = store.getString("editor/display/scrollbar_visibility");
		if (store.registry.exists("editor/display/minimap_enabled") && (base == null || !store.isDefault("editor/display/minimap_enabled"))) value.minimapEnabled = store.getBool("editor/display/minimap_enabled");
		if (store.registry.exists("editor/display/word_wrap") && (base == null || !store.isDefault("editor/display/word_wrap"))) value.wordWrap = store.getBool("editor/display/word_wrap");
		if (store.registry.exists("editor/display/render_whitespace") && (base == null || !store.isDefault("editor/display/render_whitespace"))) value.renderWhitespace = store.getString("editor/display/render_whitespace");
		if (store.registry.exists("editor/display/tab_tooltip_delay") && (base == null || !store.isDefault("editor/display/tab_tooltip_delay"))) value.tabTooltipDelay = store.getFloat("editor/display/tab_tooltip_delay");
		if (store.registry.exists("editor/indentation/tab_width") && (base == null || !store.isDefault("editor/indentation/tab_width"))) value.tabWidth = store.getInt("editor/indentation/tab_width");
		if (store.registry.exists("editor/indentation/insert_spaces") && (base == null || !store.isDefault("editor/indentation/insert_spaces"))) value.insertSpaces = store.getBool("editor/indentation/insert_spaces");
		if (store.registry.exists("editor/display/scroll_animation_type") && (base == null || !store.isDefault("editor/display/scroll_animation_type"))) value.scrollAnimationType = store.getString("editor/display/scroll_animation_type");
		if (store.registry.exists("editor/display/scroll_animation_duration") && (base == null || !store.isDefault("editor/display/scroll_animation_duration"))) value.scrollAnimationDuration = store.getFloat("editor/display/scroll_animation_duration");
		if (store.registry.exists("languages/haxeon/enabled") && (base == null || !store.isDefault("languages/haxeon/enabled"))) value.haxeonEnabled = store.getBool("languages/haxeon/enabled");
		if (store.registry.exists("languages/haxeon/command") && (base == null || !store.isDefault("languages/haxeon/command"))) value.haxeonCommand = strings(store.getString("languages/haxeon/command"));
		if (store.registry.exists("languages/haxeon/verbose") && (base == null || !store.isDefault("languages/haxeon/verbose"))) value.haxeonVerbose = store.getBool("languages/haxeon/verbose");
		if (store.registry.exists("files/explorer/excluded_names") && (base == null || !store.isDefault("files/explorer/excluded_names"))) value.excludedNames = strings(store.getString("files/explorer/excluded_names"));
		if (store.registry.exists("search/results/case_sensitive") && (base == null || !store.isDefault("search/results/case_sensitive"))) value.searchCaseSensitive = store.getBool("search/results/case_sensitive");
		if (store.registry.exists("search/results/whole_word") && (base == null || !store.isDefault("search/results/whole_word"))) value.searchWholeWord = store.getBool("search/results/whole_word");
		if (store.registry.exists("search/results/max_results") && (base == null || !store.isDefault("search/results/max_results"))) value.searchMaxResults = store.getInt("search/results/max_results");
		if (store.registry.exists("scm/enabled") && (base == null || !store.isDefault("scm/enabled"))) value.scmEnabled = store.getBool("scm/enabled");
		if (store.registry.exists("scm/git_path") && (base == null || !store.isDefault("scm/git_path"))) value.scmGitPath = store.getString("scm/git_path");
		if (store.registry.exists("scm/untracked_limit") && (base == null || !store.isDefault("scm/untracked_limit"))) value.scmUntrackedLimit = store.getInt("scm/untracked_limit");
		if (store.registry.exists("scm/diff_size_limit") && (base == null || !store.isDefault("scm/diff_size_limit"))) value.scmDiffSizeLimit = store.getInt("scm/diff_size_limit");
		if (store.registry.exists("scm/nested_scan_depth") && (base == null || !store.isDefault("scm/nested_scan_depth"))) value.scmNestedScanDepth = store.getInt("scm/nested_scan_depth");
		if (store.registry.exists("scm/auto_refresh") && (base == null || !store.isDefault("scm/auto_refresh"))) value.scmAutoRefresh = store.getBool("scm/auto_refresh");
		if (store.registry.exists("scm/auto_fetch") && (base == null || !store.isDefault("scm/auto_fetch"))) value.scmAutoFetch = store.getBool("scm/auto_fetch");
		if (store.registry.exists("scm/commit_all_when_nothing_staged") && (base == null || !store.isDefault("scm/commit_all_when_nothing_staged")))
			value.scmCommitAllWhenNothingStaged = store.getBool("scm/commit_all_when_nothing_staged");
		if (store.registry.exists("scm/gutter") && (base == null || !store.isDefault("scm/gutter"))) value.scmGutter = store.getBool("scm/gutter");
		if (store.registry.exists("scm/explorer_decorations") && (base == null || !store.isDefault("scm/explorer_decorations"))) value.scmExplorerDecorations = store.getBool("scm/explorer_decorations");
		if (store.registry.exists("appearance/colors/editor_background") && (base == null || !store.isDefault("appearance/colors/editor_background"))) value.editorBackground = store.getInt("appearance/colors/editor_background");
		if (store.registry.exists("appearance/colors/editor_foreground") && (base == null || !store.isDefault("appearance/colors/editor_foreground"))) value.editorForeground = store.getInt("appearance/colors/editor_foreground");
		if (store.registry.exists("appearance/colors/accent") && (base == null || !store.isDefault("appearance/colors/accent"))) value.accent = store.getInt("appearance/colors/accent");
		if (store.registry.exists("appearance/colors/surface") && (base == null || !store.isDefault("appearance/colors/surface"))) value.surface = store.getInt("appearance/colors/surface");
		if (store.registry.exists("appearance/colors/surface_elevated") && (base == null || !store.isDefault("appearance/colors/surface_elevated"))) value.surfaceElevated = store.getInt("appearance/colors/surface_elevated");
		if (store.registry.exists("appearance/colors/surface_active") && (base == null || !store.isDefault("appearance/colors/surface_active"))) value.surfaceActive = store.getInt("appearance/colors/surface_active");
		if (store.registry.exists("appearance/colors/surface_inactive") && (base == null || !store.isDefault("appearance/colors/surface_inactive"))) value.surfaceInactive = store.getInt("appearance/colors/surface_inactive");
		if (store.registry.exists("appearance/colors/surface_hover") && (base == null || !store.isDefault("appearance/colors/surface_hover"))) value.surfaceHover = store.getInt("appearance/colors/surface_hover");
		if (store.registry.exists("appearance/colors/border") && (base == null || !store.isDefault("appearance/colors/border"))) value.border = store.getInt("appearance/colors/border");
		if (store.registry.exists("appearance/colors/divider") && (base == null || !store.isDefault("appearance/colors/divider"))) value.divider = store.getInt("appearance/colors/divider");
		if (store.registry.exists("appearance/colors/foreground_muted") && (base == null || !store.isDefault("appearance/colors/foreground_muted"))) value.foregroundMuted = store.getInt("appearance/colors/foreground_muted");
		if (store.registry.exists("appearance/colors/foreground_subtle") && (base == null || !store.isDefault("appearance/colors/foreground_subtle"))) value.foregroundSubtle = store.getInt("appearance/colors/foreground_subtle");
		if (store.registry.exists("appearance/colors/foreground_disabled") && (base == null || !store.isDefault("appearance/colors/foreground_disabled"))) value.foregroundDisabled = store.getInt("appearance/colors/foreground_disabled");
		if (store.registry.exists("appearance/colors/selection") && (base == null || !store.isDefault("appearance/colors/selection"))) value.selection = store.getInt("appearance/colors/selection");
		if (store.registry.exists("appearance/colors/search_match") && (base == null || !store.isDefault("appearance/colors/search_match"))) value.searchMatch = store.getInt("appearance/colors/search_match");
		if (store.registry.exists("appearance/colors/caret") && (base == null || !store.isDefault("appearance/colors/caret"))) value.caret = store.getInt("appearance/colors/caret");
		if (store.registry.exists("appearance/colors/overlay") && (base == null || !store.isDefault("appearance/colors/overlay"))) value.overlay = store.getInt("appearance/colors/overlay");
		if (store.registry.exists("appearance/colors/information") && (base == null || !store.isDefault("appearance/colors/information"))) value.information = store.getInt("appearance/colors/information");
		if (store.registry.exists("appearance/colors/warning") && (base == null || !store.isDefault("appearance/colors/warning"))) value.warning = store.getInt("appearance/colors/warning");
		if (store.registry.exists("appearance/colors/error") && (base == null || !store.isDefault("appearance/colors/error"))) value.error = store.getInt("appearance/colors/error");
		if (store.registry.exists("appearance/colors/scrollbar") && (base == null || !store.isDefault("appearance/colors/scrollbar"))) value.scrollbar = store.getInt("appearance/colors/scrollbar");
		if (store.registry.exists("editor/keyboard/keybindings") && (base == null || !store.isDefault("editor/keyboard/keybindings"))) value.keybindings = bindings(store.getString("editor/keyboard/keybindings"));
		if (value.haxeonCommand.length > 0 && value.haxeonCommand[0].length == 0) throw "Language server executable cannot be empty";
		if (store.registry.exists("terminal/fonts/font_size")) value.terminalFontSize = store.getInt("terminal/fonts/font_size");
		if (store.registry.exists("terminal/keyboard/commands_to_skip_shell") && (base == null || !store.isDefault("terminal/keyboard/commands_to_skip_shell")))
			value.terminalCommandsToSkipShell = strings(store.getString("terminal/keyboard/commands_to_skip_shell"));
		return value;
	}

	public static function strings(text:String):Array<String> {
		var parsed:Dynamic = haxe.Json.parse(text);
		if (!Std.isOfType(parsed, Array)) throw "Expected a JSON array of strings";
		var result:Array<String> = [];
		for (item in (cast parsed:Array<Dynamic>)) {
			if (!Std.isOfType(item, String)) throw "Expected a JSON array of strings";
			result.push(cast item);
		}
		return result;
	}

	public static function bindings(text:String):Array<ConfiguredKeyBinding> {
		var result:Array<ConfiguredKeyBinding> = [];
		for (entry in strings(text)) {
			var pieces = entry.split("|");
			if (pieces.length != 2) throw "Keybinding must be Shortcut|command: name";
			var parsed = parseBinding(entry);
			if (parsed == null) throw "Invalid shortcut: " + pieces[0];
			result.push(new ConfiguredKeyBinding(parsed.key, parsed.modifiers, parsed.commands));
		}
		return result;
	}
	static function parseBinding(value:String):Null<ConfiguredKeyBinding> {
		var separator = value.indexOf("|");
		if (separator < 1 || separator == value.length - 1) {
			return null;
		}
		var chord = value.substring(0, separator).split("+"), key = 0, modifiers = 0;
		for (part in chord) {
			var name = StringTools.trim(part).toLowerCase();
			if (name == "ctrl") modifiers += Platform.MOD_CTRL;
			else if (name == "shift") modifiers += Platform.MOD_SHIFT;
			else if (name == "alt") modifiers += Platform.MOD_ALT;
			else if (key == 0) key = keyNamed(name);
			else key = 0;
		}
		var commands = [for (part in value.substring(separator + 1).split(",")) StringTools.trim(part)];
		if (key == 0 || commands.length == 0) {
			return null;
		}
		return new ConfiguredKeyBinding(key, modifiers, commands);
	}

	static function keyNamed(name:String):Int
		return switch name {
			case "a": Platform.KEY_A; case "s": Platform.KEY_S; case "y": Platform.KEY_Y; case "z": Platform.KEY_Z;
			case "w": Platform.KEY_W; case "p": Platform.KEY_P; case "f": Platform.KEY_F; case "h": Platform.KEY_H;
			case "c": Platform.KEY_C; case "v": Platform.KEY_V; case "x": Platform.KEY_X; case "k": Platform.KEY_K; case "j": Platform.KEY_J;
			case "d": Platform.KEY_D;
			case "f12": Platform.KEY_F12;
			case "g": Platform.KEY_G;
			case "b": Platform.KEY_B;
			case "tab": Platform.KEY_TAB; case "enter": Platform.KEY_ENTER; case "escape": Platform.KEY_ESCAPE;
			case "backspace": Platform.KEY_BACKSPACE; case "delete": Platform.KEY_DELETE; case "left": Platform.KEY_LEFT;
			case "right": Platform.KEY_RIGHT; case "up": Platform.KEY_UP; case "down": Platform.KEY_DOWN;
			case "home": Platform.KEY_HOME; case "end": Platform.KEY_END; case "pageup": Platform.KEY_PAGE_UP;
			case "pagedown": Platform.KEY_PAGE_DOWN; case "slash": Platform.KEY_SLASH; default: 0;
		};

}

private class ArraySettingDefinition extends SettingDefinition {
	override public function validate(value:PropertyValue):Null<String> {
		var error = super.validate(value);
		if (error != null) return error;
		switch (value) {
			case Text(text):
				try {
					var items = PreferencesRegistry.strings(text);
					if (path == "editor/keyboard/keybindings") PreferencesRegistry.bindings(text);
					if (path == "languages/haxeon/command" && items.length > 0 && StringTools.trim(items[0]).length == 0)
						throw "Language server executable cannot be empty";
					return null;
				} catch (error:Dynamic) { return Std.string(error); }
			default: return "Expected a JSON array of strings";
		}
	}
}
