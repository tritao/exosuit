package testing.model;

import view.View;
import view.LayoutKind;

import style.Theme;

class ModelWelcomeView {
	public static inline final BUTTON_WIDTH = 170;
	public static inline final BUTTON_HEIGHT = 32;
	public static inline final BUTTON_GAP = 10;
	public var newFile:Void->Void = function() {};
	public var openFile:Void->Void = function() {};
	public var openProject:Void->Void = function() {};
	public var findFile:Void->Void = function() {};
	public var runCommand:Void->Void = function() {};
	public var openSettings:Void->Void = function() {};
	public var openPlugins:Void->Void = function() {};
	public var openRecent:String->Void = function(path) {};
	public var recentProjects:Array<String> = [];
	var pointerX:Int = -1;
	var pointerY:Int = -1;

	public function new() {}
	public function mouseMove(x:Int, y:Int):Void { pointerX = x; pointerY = y; }

	public function mouseDown(x:Int, y:Int, left:Int, top:Int, width:Int, height:Int):Bool {
		var originX = left + Std.int((width - (BUTTON_WIDTH * 2 + BUTTON_GAP)) / 2), originY = top + 150;
		var actions = [newFile, openFile, openProject, findFile, runCommand, openSettings, openPlugins];
		for (index in 0...actions.length) {
			var column = index % 2, row = Std.int(index / 2), bx = originX + column * (BUTTON_WIDTH + BUTTON_GAP), by = originY + row * (BUTTON_HEIGHT + BUTTON_GAP);
			if (inside(x, y, bx, by, BUTTON_WIDTH, BUTTON_HEIGHT)) { actions[index](); return true; }
		}
		var recentY = originY + 4 * (BUTTON_HEIGHT + BUTTON_GAP) + 38;
		for (index in 0...recentProjects.length)
			if (inside(x, y, originX, recentY + index * 25, BUTTON_WIDTH * 2 + BUTTON_GAP, 24)) { openRecent(recentProjects[index]); return true; }
		return false;
	}

	static inline function inside(px:Int, py:Int, x:Int, y:Int, width:Int, height:Int):Bool
		return px >= x && px < x + width && py >= y && py < y + height;
}
