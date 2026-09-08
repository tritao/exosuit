package view;

import completion.CompletionItem;
import platform.Platform;
import platform.TextInputArea;
import renderer.Renderer;
import style.Theme;
import language.SignatureHelp;

/** Caret-anchored presentation shared by completion and language information. */
class AnchoredPopup {
	public static inline final WIDTH = 360;
	public static inline final ROW_HEIGHT = 25;
	public static inline final MAX_ROWS = 8;
	public var visible(default, null):Bool = false;
	final items:Array<CompletionItem> = [];
	var selected:Int = 0;
	var information:String = "";
	var emphasized:String = "";
	var accept:CompletionItem->Void = function(item) {};
	var anchor:Null<TextInputArea>;

	public function new() {}

	public function openCompletion(anchor:TextInputArea, values:Array<CompletionItem>, accept:CompletionItem->Void):Void {
		items.resize(0);
		for (value in values) items.push(value);
		this.anchor = anchor;
		this.accept = accept;
		information = "";
		emphasized = "";
		selected = 0;
		visible = items.length > 0;
	}

	public function openInformation(anchor:TextInputArea, value:String):Void {
		items.resize(0);
		this.anchor = anchor;
		information = value;
		emphasized = "";
		visible = value.length > 0;
	}

	public function openSignature(anchor:TextInputArea, value:SignatureHelp):Void {
		items.resize(0);
		this.anchor = anchor;
		information = value.label + (value.documentation.length == 0 ? "" : "\n" + value.documentation);
		emphasized = value.activeParameter;
		visible = true;
	}

	public function close():Void visible = false;

	public function keyPressed(key:Int, modifiers:Int):Bool {
		if (!visible) return false;
		if (key == Platform.KEY_ESCAPE) { close(); return true; }
		if (items.length == 0) return false;
		if (key == Platform.KEY_DOWN) { selected = (selected + 1) % items.length; return true; }
		if (key == Platform.KEY_UP) { selected = (selected + items.length - 1) % items.length; return true; }
		if (key == Platform.KEY_ENTER || key == Platform.KEY_TAB) {
			var item = items[selected];
			close();
			accept(item);
			return true;
		}
		return false;
	}

	public function draw(renderer:Renderer, theme:Theme, viewportWidth:Int, viewportHeight:Int):Void {
		if (!visible || anchor == null) return;
		var x = anchor.x, y = anchor.y + anchor.height + 2;
		var rows = items.length < MAX_ROWS ? items.length : MAX_ROWS;
		var height = items.length == 0 ? renderer.lineHeight * 3 : rows * ROW_HEIGHT;
		if (x + WIDTH > viewportWidth) x = viewportWidth - WIDTH;
		if (y + height > viewportHeight) y = anchor.y - height - 2;
		if (x < 0) x = 0;
		if (y < 0) y = 0;
		renderer.rect(x - 1, y - 1, WIDTH + 2, height + 2, theme.border);
		renderer.rect(x, y, WIDTH, height, theme.surfaceElevated);
		if (items.length == 0) {
			drawInformation(renderer, theme, x, y);
			return;
		}
		var start = selected >= MAX_ROWS ? selected - MAX_ROWS + 1 : 0, end = start + rows;
		if (end > items.length) end = items.length;
		for (index in start...end) {
			var rowY = y + (index - start) * ROW_HEIGHT, item = items[index];
			if (index == selected) renderer.rect(x, rowY, WIDTH, ROW_HEIGHT, theme.selection);
			renderer.text(x + 9, rowY + 4, item.label, theme.editorForeground);
			if (item.detail.length > 0) {
				var detailWidth = renderer.textWidth(item.detail);
				renderer.text(x + WIDTH - detailWidth - 9, rowY + 4, item.detail, theme.foregroundMuted);
			}
		}
	}

	function drawInformation(renderer:Renderer, theme:Theme, x:Int, y:Int):Void {
		var lines = information.split("\n"), count = lines.length < 3 ? lines.length : 3;
		for (index in 0...count) renderer.text(x + 9, y + 5 + index * renderer.lineHeight, lines[index], theme.editorForeground);
		if (emphasized.length > 0) renderer.text(x + 9, y + 5 + 2 * renderer.lineHeight, emphasized, theme.accent);
	}
}
