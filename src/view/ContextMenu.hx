package view;

import renderer.Renderer;
import style.Theme;

class ContextMenu {
	public static inline final WIDTH = 190;
	public static inline final ROW_HEIGHT = 28;
	public var visible(default, null):Bool = false;
	final items:Array<ContextMenuItem> = [];
	var x:Int = 0;
	var y:Int = 0;
	var pointerX:Int = -1;
	var pointerY:Int = -1;

	public function new() {}

	public function open(x:Int, y:Int, items:Array<ContextMenuItem>, viewportWidth:Int, viewportHeight:Int):Void {
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

	public function draw(renderer:Renderer, theme:Theme):Void {
		if (!visible) return;
		var height = items.length * ROW_HEIGHT;
		renderer.rect(x - 1, y - 1, WIDTH + 2, height + 2, theme.border);
		renderer.rect(x, y, WIDTH, height, theme.surfaceElevated);
		for (index in 0...items.length) {
			var rowY = y + index * ROW_HEIGHT;
			if (pointerX >= x && pointerX < x + WIDTH && pointerY >= rowY && pointerY < rowY + ROW_HEIGHT)
				renderer.rect(x, rowY, WIDTH, ROW_HEIGHT, theme.surfaceHover);
			renderer.text(x + 12, rowY + 5, items[index].label, theme.editorForeground);
		}
	}
}
