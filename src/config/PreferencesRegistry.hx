package config;

import nativekit.ui.settings.SettingsRegistry;
import nativekit.ui.settings.SettingOptions;
import nativekit.ui.settings.SettingsStore;
import nativekit.ui.settings.SettingDefinition;
import platform.Platform;
import nativekit.ui.properties.PropertyType;
import nativekit.ui.properties.PropertyValue;
import nativekit.ui.properties.PropertyOption;

/** Exosuit definitions and typed snapshots over UIKit settings. */
class PreferencesRegistry {
	public static function create(projectOnly:Bool = false):SettingsRegistry {
		var registry = new SettingsRegistry(), defaults = new Settings();
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
			if (!projectOnly) registry.define("editor/fonts/font_size", PropertyType.Int, PropertyValue.Int(defaults.fontSize), options);
		}
		{
			var options = new SettingOptions();
			options.minimum = 70; options.maximum = 200; options.step = 10;
			options.tooltip = "Scale the whole application independently of editor font size.";
			if (!projectOnly) registry.define("appearance/workbench/zoom_percent", PropertyType.Int, PropertyValue.Int(defaults.applicationZoom), options);
		}
		{
			var options = new SettingOptions();
			options.minimum = 100; options.maximum = 1200;
			if (!projectOnly) registry.define("appearance/workbench/sidebar_width", PropertyType.Int, PropertyValue.Int(defaults.sidebarWidth), options);
		}
		{
			var options = new SettingOptions();
			options.options = [new PropertyOption("auto", "Auto"), new PropertyOption("always", "Always"), new PropertyOption("hidden", "Hidden")];
			if (!projectOnly) registry.define("editor/display/scrollbar_visibility", PropertyType.Enum, PropertyValue.Enum(defaults.scrollbarVisibility), options);
		}
		{
			var options = new SettingOptions();
			if (!projectOnly) registry.define("editor/display/minimap_enabled", PropertyType.Bool, PropertyValue.Bool(defaults.minimapEnabled), options);
		}
		{
			var options = new SettingOptions();
			options.minimum = 0; options.maximum = 5;
			if (!projectOnly) registry.define("editor/display/tab_tooltip_delay", PropertyType.Float, PropertyValue.Float(defaults.tabTooltipDelay), options);
		}

		{
			var options = new SettingOptions();
			options.minimum = 1; options.maximum = 16;
			if (!projectOnly) registry.define("editor/indentation/tab_width", PropertyType.Int, PropertyValue.Int(defaults.tabWidth), options);
		}
		{
			var options = new SettingOptions();
			if (!projectOnly) registry.define("editor/indentation/insert_spaces", PropertyType.Bool, PropertyValue.Bool(defaults.insertSpaces), options);
		}
		{
			var options = new SettingOptions();
			options.options = [new PropertyOption("smooth", "Smooth"), new PropertyOption("none", "None")];
			if (!projectOnly) registry.define("editor/display/scroll_animation_type", PropertyType.Enum, PropertyValue.Enum(defaults.scrollAnimationType), options);
		}
		{
			var options = new SettingOptions();
			options.minimum = 0; options.maximum = 0.3;
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
			if (!projectOnly) registry.define("search/results/case_sensitive", PropertyType.Bool, PropertyValue.Bool(defaults.searchCaseSensitive), options);
		}
		{
			var options = new SettingOptions();
			if (!projectOnly) registry.define("search/results/whole_word", PropertyType.Bool, PropertyValue.Bool(defaults.searchWholeWord), options);
		}
		{
			var options = new SettingOptions();
			options.minimum = 1; options.maximum = 1000000;
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
			options.minimum = 6; options.maximum = 48;
			registry.define("terminal/fonts/font_size", PropertyType.Int, PropertyValue.Int(defaults.terminalFontSize), options);
		}
		return registry;
	}

	public static function snapshot(store:SettingsStore, ?base:Settings):Settings {
		var value = base == null ? new Settings() : base.copy();
		if (store.registry.exists("appearance/workbench/zoom_percent") && (base == null || !store.isDefault("appearance/workbench/zoom_percent"))) value.applicationZoom = store.getInt("appearance/workbench/zoom_percent");
		if (store.registry.exists("editor/fonts/font_path") && (base == null || !store.isDefault("editor/fonts/font_path"))) value.fontPath = store.getString("editor/fonts/font_path");
		if (store.registry.exists("editor/fonts/font_fallback_paths") && (base == null || !store.isDefault("editor/fonts/font_fallback_paths"))) value.fontFallbackPaths = strings(store.getString("editor/fonts/font_fallback_paths"));
		if (store.registry.exists("editor/fonts/font_size") && (base == null || !store.isDefault("editor/fonts/font_size"))) value.fontSize = store.getInt("editor/fonts/font_size");
		if (store.registry.exists("appearance/workbench/sidebar_width") && (base == null || !store.isDefault("appearance/workbench/sidebar_width"))) value.sidebarWidth = store.getInt("appearance/workbench/sidebar_width");
		if (store.registry.exists("editor/display/scrollbar_visibility") && (base == null || !store.isDefault("editor/display/scrollbar_visibility"))) value.scrollbarVisibility = store.getString("editor/display/scrollbar_visibility");
		if (store.registry.exists("editor/display/minimap_enabled") && (base == null || !store.isDefault("editor/display/minimap_enabled"))) value.minimapEnabled = store.getBool("editor/display/minimap_enabled");
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
