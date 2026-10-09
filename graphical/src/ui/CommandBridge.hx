package ui;

import command.CommandContext;
import command.CommandRegistry;
import command.Keymap;
import haxeon.ui.core.Command;
import haxeon.ui.core.CommandRegistry as UiCommandRegistry;
import haxeon.ui.core.Shortcut;
import haxeon.ui.core.UiKey;
import haxeon.ui.core.UiModifier;
import platform.Platform;

/**
 * Registers every `command.CommandRegistry` command (the exosuit domain
 * commands `controller.*`/`command.EditorCommands` install: `doc:*`,
 * `file:*`, `workbench:*`, `build:*`, `language:*`, ...) onto `ui.commands`
 * (the `haxeon.ui.core.CommandRegistry` `ExosuitApp`'s `CommandPalette`
 * already reads), so that palette lists them alongside `ExosuitApp`'s own
 * `file.*`/`view.toggle-palette` entries. Each bridged command's enabled
 * state and action re-check the exosuit registry live (through `context`)
 * on every palette open/keystroke, so disabling e.g. `doc:save` when there
 * is no active document flows through automatically.
 *
 * `layoutOnlyCommands` are legacy project-tree navigation commands. `duplicates`
 * are excluded because `ExosuitApp` already exposes the same action under
 * its own `file.*`/`view.toggle-palette` ids, retargeted to call these same
 * exosuit commands (see `ExosuitApp.installCommands`).
 */
class CommandBridge {
	static final layoutOnlyCommands:Array<String> = [
		"project:sidebar-next", "project:sidebar-previous",
		"project:sidebar-open"
	];
	static final duplicates:Array<String> = ["file:new", "doc:save", "root:close", "settings:open"];

	public static function install(target:UiCommandRegistry, source:CommandRegistry, keymap:Keymap, context:CommandContext):Void {
		for (id in target.ids())
			if (StringTools.startsWith(id, "exosuit.") && !source.contains(id.substring(8))) target.unregister(id);
		for (command in source.all()) {
			if (layoutOnlyCommands.indexOf(command.name) >= 0 || duplicates.indexOf(command.name) >= 0) continue;
			var name = command.name;
			var existing = target.get(bridgedId(name));
			if (existing != null && existing.label == command.description) continue;
			if (existing != null) target.unregister(existing.id);
			var shortcuts = shortcutsFor(keymap, name);
			var bridged = new Command(bridgedId(name), command.description, function() {
				source.perform(name, context);
			}, shortcuts.length == 0 ? null : shortcuts[0], function() return source.isValid(name, context));
			bridged.repeatable = ["doc:tab", "doc:indent", "doc:unindent", "doc:backspace", "doc:delete", "doc:newline"].indexOf(name) >= 0;
			for (shortcut in shortcuts) bridged.addShortcut(shortcut);
			target.register(bridged);
		}
		refreshShortcuts(target, source, keymap);
	}

	/** `haxeon.ui.core.CommandRegistry` ids are namespaced separately from `ExosuitApp`'s own dotted ids; the colon survives untouched since nothing else uses it. */
	static function bridgedId(name:String):String
		return "exosuit." + name;

	public static function refreshShortcuts(target:UiCommandRegistry, source:CommandRegistry, keymap:Keymap):Void {
		for (command in source.all()) {
			var id = "exosuit." + command.name;
			if (target.get(id) == null) continue;
			target.setShortcuts(id, shortcutsFor(keymap, command.name));
		}
	}

	static function shortcutsFor(keymap:Keymap, name:String):Array<Shortcut> {
		var result:Array<Shortcut> = [];
		for (binding in keymap.effectiveBindings())
			if (binding.commands.indexOf(name) >= 0) {
				var key = uiKeyFor(binding.key);
				if (key < 0) continue;
				result.push(new Shortcut(key, uiModifiersFor(binding.modifiers)));
			}
		return result;
	}

	/** Navigation history takes precedence over TextArea's Alt+arrow word motion. */
	public static function navigationKey(keymap:Keymap, context:CommandContext, key:Int, modifiers:Int):Bool {
		for (binding in keymap.effectiveBindings())
			if ((binding.commands.indexOf("navigation:go-back") >= 0 || binding.commands.indexOf("navigation:go-forward") >= 0) &&
				uiKeyFor(binding.key) == key && uiModifiersFor(binding.modifiers) == modifiers)
				return keymap.onKeyPressed(binding.key, binding.modifiers, context);
		return false;
	}

	static function uiKeyFor(key:Int):Int
		return switch key {
			case Platform.KEY_F12: UiKey.F12;
			case Platform.KEY_ESCAPE: UiKey.Escape;
			case Platform.KEY_ENTER: UiKey.Enter;
			case Platform.KEY_TAB: UiKey.Tab;
			case Platform.KEY_BACKSPACE: UiKey.Backspace;
			case Platform.KEY_DELETE: UiKey.Delete;
			case Platform.KEY_INSERT: UiKey.Insert;
			case Platform.KEY_DOWN: UiKey.Down;
			case Platform.KEY_UP: UiKey.Up;
			case Platform.KEY_PAGE_UP: UiKey.PageUp;
			case Platform.KEY_PAGE_DOWN: UiKey.PageDown;
			case Platform.KEY_RIGHT: UiKey.Right;
			case Platform.KEY_LEFT: UiKey.Left;
			case Platform.KEY_HOME: UiKey.Home;
			case Platform.KEY_END: UiKey.End;
			case Platform.KEY_A: UiKey.A;
			case Platform.KEY_C: UiKey.C;
			case Platform.KEY_S: UiKey.S;
			case Platform.KEY_Y: UiKey.Y;
			case Platform.KEY_Z: UiKey.Z;
			case Platform.KEY_V: UiKey.V;
			case Platform.KEY_X: UiKey.X;
			case Platform.KEY_SPACE: UiKey.Space;
			case Platform.KEY_SLASH: UiKey.Slash;
			case Platform.KEY_W: UiKey.W;
			case Platform.KEY_P: UiKey.P;
			case Platform.KEY_F: UiKey.F;
			case Platform.KEY_H: UiKey.H;
			case Platform.KEY_K: UiKey.K;
			case Platform.KEY_J: UiKey.J;
			case Platform.KEY_D: UiKey.D;
			case Platform.KEY_G: UiKey.G;
			case Platform.KEY_B: UiKey.B;
			default: -1;
		};

	static function uiModifiersFor(modifiers:Int):Int {
		var result = 0;
		if ((modifiers & Platform.MOD_SHIFT) != 0) result |= UiModifier.Shift;
		if ((modifiers & Platform.MOD_CTRL) != 0) result |= UiModifier.Control;
		if ((modifiers & Platform.MOD_ALT) != 0) result |= UiModifier.Alt;
		return result;
	}
}
