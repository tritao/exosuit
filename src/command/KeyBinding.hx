package command;

import platform.Platform;

class KeyBinding {
	public final key:Int;
	public final modifiers:Int;
	public final commands:Array<String>;

	public function new(key:Int, modifiers:Int, commands:Array<String>) {
		this.key = key;
		this.modifiers = modifiers;
		this.commands = commands;
	}

	public function displayName():String {
		var result = "";
		if (modifiers & Platform.MOD_CTRL != 0) result += "Ctrl+";
		if (modifiers & Platform.MOD_SHIFT != 0) result += "Shift+";
		if (modifiers & Platform.MOD_ALT != 0) result += "Alt+";
		return result + keyName(key);
	}

	static function keyName(key:Int):String
		return switch key {
			case Platform.KEY_BACKSPACE: "Backspace"; case Platform.KEY_TAB: "Tab"; case Platform.KEY_ENTER: "Enter";
			case Platform.KEY_INSERT: "Insert"; case Platform.KEY_ESCAPE: "Escape"; case Platform.KEY_DELETE: "Delete"; case Platform.KEY_LEFT: "Left";
			case Platform.KEY_RIGHT: "Right"; case Platform.KEY_UP: "Up"; case Platform.KEY_DOWN: "Down";
			case Platform.KEY_HOME: "Home"; case Platform.KEY_END: "End"; case Platform.KEY_A: "A"; case Platform.KEY_S: "S";
			case Platform.KEY_Y: "Y"; case Platform.KEY_Z: "Z"; case Platform.KEY_W: "W"; case Platform.KEY_P: "P";
			case Platform.KEY_F: "F"; case Platform.KEY_H: "H"; case Platform.KEY_C: "C"; case Platform.KEY_V: "V";
			case Platform.KEY_X: "X"; case Platform.KEY_PAGE_UP: "PageUp"; case Platform.KEY_PAGE_DOWN: "PageDown";
			case Platform.KEY_K: "K"; case Platform.KEY_J: "J"; case Platform.KEY_SLASH: "/"; case Platform.KEY_D: "D";
			case Platform.KEY_G: "G"; case Platform.KEY_B: "B"; case Platform.KEY_SPACE: "Space";
			default: Std.string(key);
		};
}
