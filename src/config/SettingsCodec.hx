package config;

import platform.Platform;

class SettingsCodec {
	public static function apply(content:String, target:Settings, source:String):Array<String> {
		var diagnostics:Array<String> = [], version = 0, bindings = [for (binding in target.keybindings) binding.copy()], lines = content.split("\n");
		for (lineNumber in 0...lines.length) {
			var line = StringTools.trim(lines[lineNumber]);
			if (line.length == 0 || StringTools.startsWith(line, "#")) continue;
			var separator = line.indexOf("=");
			if (separator < 1) {
				diagnostics.push(source + ":" + (lineNumber + 1) + ": expected key=value");
				continue;
			}
			var key = StringTools.trim(line.substring(0, separator)), value = StringTools.trim(line.substring(separator + 1));
			if (key == "version") version = parseBoundedInt(value, 1, Settings.VERSION, key, source, lineNumber, diagnostics);
			else if (key == "editor.fontPath") target.fontPath = ApplicationPaths.relativeToFile(requireText(value, key, source, lineNumber,
				diagnostics), source);
			else if (key == "editor.fontFallbacks") target.fontFallbackPaths = [for (path in parseList(value)) ApplicationPaths.relativeToFile(path, source)];
			else if (key == "editor.fontSize") target.fontSize = parseBoundedInt(value, 6, 96, key, source, lineNumber, diagnostics);
			else if (key == "workbench.sidebarWidth") target.sidebarWidth = parseBoundedInt(value, 120, 600, key, source, lineNumber, diagnostics);
			else if (key == "editor.tabWidth") target.tabWidth = parseBoundedInt(value, 1, 16, key, source, lineNumber, diagnostics);
			else if (key == "editor.insertSpaces") target.insertSpaces = parseBool(value, key, source, lineNumber, diagnostics);
			else if (key == "editor.scroll_animation_type") {
				if (value == "smooth" || value == "none") target.scrollAnimationType = value;
				else diagnostics.push(source + ":" + (lineNumber + 1) + ": scroll_animation_type must be smooth or none");
			} else if (key == "editor.scroll_animation_duration") {
				var duration = Std.parseFloat(value);
				if (!~/^[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?$/.match(value) || !Math.isFinite(duration) || duration < 0 || duration > 0.3)
					diagnostics.push(source + ":" + (lineNumber + 1) + ": scroll_animation_duration must be seconds from 0 to 0.3");
				else target.scrollAnimationDuration = duration;
			} else if (key == "plugins.haxeon.enabled") target.haxeonEnabled = parseBool(value, key, source, lineNumber, diagnostics);
			else if (key == "plugins.haxeon.verbose") target.haxeonVerbose = parseBool(value, key, source, lineNumber, diagnostics);
			else if (key == "plugins.haxeon.command") target.haxeonCommand = parseCommand(value, source, lineNumber, diagnostics);
			else if (key == "files.exclude") target.excludedNames = parseList(value);
			else if (key == "search.caseSensitive") target.searchCaseSensitive = parseBool(value, key, source, lineNumber, diagnostics);
			else if (key == "search.wholeWord") target.searchWholeWord = parseBool(value, key, source, lineNumber, diagnostics);
			else if (key == "search.maxResults") target.searchMaxResults = parseBoundedInt(value, 1, 1000000, key, source, lineNumber, diagnostics);
			else if (key == "theme.editorBackground") target.editorBackground = parseColor(value, key, source, lineNumber, diagnostics);
			else if (key == "theme.editorForeground") target.editorForeground = parseColor(value, key, source, lineNumber, diagnostics);
			else if (key == "theme.accent") target.accent = parseColor(value, key, source, lineNumber, diagnostics);
			else if (StringTools.startsWith(key, "theme.")) applyThemeColor(key, value, target, source, lineNumber, diagnostics);
			else if (key == "keybinding") {
				var binding = parseBinding(value, source, lineNumber, diagnostics);
				if (binding != null) {
					var index = bindings.length;
					while (index > 0) {
						index--;
						if (bindings[index].key == binding.key && bindings[index].modifiers == binding.modifiers) bindings.splice(index, 1);
					}
					bindings.push(binding);
				}
			} else diagnostics.push(source + ":" + (lineNumber + 1) + ': unknown setting "$key"');
		}
		if (version == 0) diagnostics.push(source + ": missing version=" + Settings.VERSION);
		target.keybindings = bindings;
		return diagnostics;
	}

	static function applyThemeColor(key:String, value:String, target:Settings, source:String, line:Int, diagnostics:Array<String>):Void {
		var color = parseColor(value, key, source, line, diagnostics);
		switch key {
			case "theme.surface": target.surface = color;
			case "theme.surfaceElevated": target.surfaceElevated = color;
			case "theme.surfaceActive": target.surfaceActive = color;
			case "theme.surfaceInactive": target.surfaceInactive = color;
			case "theme.surfaceHover": target.surfaceHover = color;
			case "theme.border": target.border = color;
			case "theme.divider": target.divider = color;
			case "theme.foregroundMuted": target.foregroundMuted = color;
			case "theme.foregroundSubtle": target.foregroundSubtle = color;
			case "theme.foregroundDisabled": target.foregroundDisabled = color;
			case "theme.selection": target.selection = color;
			case "theme.searchMatch": target.searchMatch = color;
			case "theme.caret": target.caret = color;
			case "theme.overlay": target.overlay = color;
			case "theme.information": target.information = color;
			case "theme.warning": target.warning = color;
			case "theme.error": target.error = color;
			case "theme.scrollbar": target.scrollbar = color;
			default: diagnostics.push(source + ":" + (line + 1) + ': unknown setting "$key"');
		}
	}

	static function parseBinding(value:String, source:String, line:Int, diagnostics:Array<String>):Null<ConfiguredKeyBinding> {
		var separator = value.indexOf("|");
		if (separator < 1 || separator == value.length - 1) {
			diagnostics.push(source + ":" + (line + 1) + ": keybinding must be chord|command[,command]");
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
		var commands = parseList(value.substring(separator + 1));
		if (key == 0 || commands.length == 0) {
			diagnostics.push(source + ":" + (line + 1) + ": invalid keybinding");
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

	static function parseCommand(value:String, source:String, line:Int, diagnostics:Array<String>):Array<String> {
		var result:Array<String> = [];
		try {
			var raw:Dynamic = haxe.Json.parse(value);
			if (!Std.isOfType(raw, Array)) throw "expected an array";
			for (item in cast(raw, Array<Dynamic>)) {
				if (!Std.isOfType(item, String)) throw "arguments must be strings";
				result.push(cast(item, String));
			}
			if (result.length > 0 && StringTools.trim(result[0]).length == 0) throw "executable must not be empty";
		} catch (error:Dynamic) {
			diagnostics.push(source + ":" + (line + 1) + ": plugins.haxeon.command must be a JSON string array: " + Std.string(error));
			return [];
		}
		return result;
	}

	static function parseList(value:String):Array<String> {
		var result:Array<String> = [];
		for (part in value.split(",")) {
			var item = StringTools.trim(part);
			if (item.length > 0) result.push(item);
		}
		return result;
	}

	static function requireText(value:String, key:String, source:String, line:Int, diagnostics:Array<String>):String {
		if (value.length == 0) diagnostics.push(source + ":" + (line + 1) + ': "$key" cannot be empty');
		return value;
	}

	static function parseBool(value:String, key:String, source:String, line:Int, diagnostics:Array<String>):Bool {
		if (value == "true") return true;
		if (value == "false") return false;
		diagnostics.push(source + ":" + (line + 1) + ': "$key" must be true or false');
		return false;
	}

	static function parseBoundedInt(value:String, minimum:Int, maximum:Int, key:String, source:String, line:Int, diagnostics:Array<String>):Int {
		var result = Std.parseInt(value);
		if (Std.string(result) != value || result < minimum || result > maximum) {
			diagnostics.push(source + ":" + (line + 1) + ': "$key" must be an integer from $minimum to $maximum');
			return minimum;
		}
		return result;
	}

	static function parseColor(value:String, key:String, source:String, line:Int, diagnostics:Array<String>):Int {
		var result = Std.parseInt(value);
		if (Std.string(result) != value) diagnostics.push(source + ":" + (line + 1) + ': "$key" must be a decimal RGBA integer');
		return result;
	}
}
