package testing.model;

import view.View;
import view.LayoutKind;

import style.Theme;

class ModelContextMenu {
	public static inline final WIDTH = 190;
	public static inline final ROW_HEIGHT = 28;
	public var visible(default, null):Bool = false;
	final items:Array<ModelContextMenuItem> = [];
	var x:Int = 0;
	var y:Int = 0;
	var pointerX:Int = -1;
	var pointerY:Int = -1;

	public function new() {}

	public function open(x:Int, y:Int, items:Array<ModelContextMenuItem>, viewportWidth:Int, viewportHeight:Int):Void {
		this.items.resize(0);
		for (item in items) this.items.push(item);
		this.x = x + WIDTH > viewportWidth ? viewportWidth - WIDTH : x;
		var menuHeight = items.length * ROW_HEIGHT;
		this.y = y + menuHeight > viewportHeight ? viewportHeight - menuHeight : y;
		if (this.x < 0) this.x = 0;
		if (this.y < 0) this.y = 0;
		visible = items.length > 0;
	}

	public function close():Void visible = false;
	public function mouseMove(x:Int, y:Int):Void { pointerX = x; pointerY = y; }

	public function mouseDown(button:Int, x:Int, y:Int):Bool {
		if (!visible) return false;
		var index = x >= this.x && x < this.x + WIDTH ? Std.int((y - this.y) / ROW_HEIGHT) : -1;
		var selected = index >= 0 && index < items.length ? items[index] : null;
		close();
		if (button == 1 && selected != null) selected.action();
		return true;
	}

}
