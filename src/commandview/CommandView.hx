package commandview;

import platform.Platform;
import renderer.Renderer;
import style.Theme;
import platform.TextInputArea;

class CommandView {
	public var active(default, null):Bool = false;
	public var query(get, never):String;
	public var selected(default, null):Int = 0;
	public final results:Array<CommandViewEntry> = [];
	public final input:CommandInput = new CommandInput();
	var provider:Null<CommandViewProvider>;
	public var compositionText(default, null):String = "";
	var compositionStart:Int = 0;
	var compositionLength:Int = 0;

	public function new() {}

	function get_query():String return input.text;

	public function open(provider:CommandViewProvider):Void {
		this.provider = provider;
		input.reset();
		clearComposition();
		selected = 0;
		active = true;
		provider.onQuery(query);
		filter();
	}

	public function close(cancel:Bool = false):Void {
		var current = provider;
		active = false;
		provider = null;
		clearComposition();
		if (cancel && current != null) current.onCancel();
	}

	public function textInput(value:String):Void {
		clearComposition();
		input.insert(value);
		changed();
	}

	public function setComposition(text:String, start:Int, length:Int):Void {
		compositionText = text;
		compositionStart = start < 0 ? 0 : start;
		compositionLength = length < 0 ? 0 : length;
	}

	public function clearComposition():Void {
		compositionText = "";
		compositionStart = 0;
		compositionLength = 0;
	}

	public function textInputArea(renderer:Renderer, windowWidth:Int):TextInputArea {
		var width = commandWidth(windowWidth), x = Std.int((windowWidth - width) / 2), inputX = x + 12,
			promptWidth = provider == null ? 0 : renderer.textWidth(provider.prompt),
			caretX = inputX + promptWidth + renderer.textWidth(query.substring(0, input.selection.cursor.column));
		return new TextInputArea(caretX, 55, 2, 24);
	}

	public function setQuery(value:String):Void {
		input.setText(value);
		changed();
	}

	public function keyPressed(key:Int, modifiers:Int):Bool {
		if (!active) return false;
		if (key == Platform.KEY_ESCAPE) close(true);
		else if (key == Platform.KEY_BACKSPACE) { if (input.backspace()) changed(); }
		else if (key == Platform.KEY_DELETE) { if (input.deleteForward()) changed(); }
		else if (key == Platform.KEY_LEFT) { moveCaret(-1, modifiers); }
		else if (key == Platform.KEY_RIGHT) { moveCaret(1, modifiers); }
		else if (key == Platform.KEY_HOME) input.moveHome((modifiers & Platform.MOD_SHIFT) != 0);
		else if (key == Platform.KEY_END) input.moveEnd((modifiers & Platform.MOD_SHIFT) != 0);
		else if (key == Platform.KEY_A && (modifiers & Platform.MOD_CTRL) != 0) input.selectAll();
		else if (key == Platform.KEY_C && (modifiers & Platform.MOD_CTRL) != 0) input.copy();
		else if (key == Platform.KEY_X && (modifiers & Platform.MOD_CTRL) != 0) { if (input.cut()) changed(); }
		else if (key == Platform.KEY_V && (modifiers & Platform.MOD_CTRL) != 0) { if (input.paste()) changed(); }
		else if (key == Platform.KEY_Z && (modifiers & Platform.MOD_CTRL) != 0) { if (input.undo()) changed(); }
		else if (key == Platform.KEY_Y && (modifiers & Platform.MOD_CTRL) != 0) { if (input.redo()) changed(); }
		else if (key == Platform.KEY_UP && (modifiers & Platform.MOD_CTRL) != 0) { if (input.moveHistory(-1)) changed(); }
		else if (key == Platform.KEY_DOWN && (modifiers & Platform.MOD_CTRL) != 0) { if (input.moveHistory(1)) changed(); }
		else if (key == Platform.KEY_UP) move(-1);
		else if (key == Platform.KEY_DOWN) move(1);
		else if (key == Platform.KEY_TAB) complete();
		else if (key == Platform.KEY_ENTER) accept((modifiers & Platform.MOD_SHIFT) != 0);
		return true;
	}

	function moveCaret(direction:Int, modifiers:Int):Void {
		var extend = (modifiers & Platform.MOD_SHIFT) != 0;
		if ((modifiers & Platform.MOD_CTRL) != 0) input.moveWord(direction, extend); else input.move(direction, extend);
	}

	function changed():Void {
		if (provider != null) provider.onQuery(query);
		filter();
	}

	function move(delta:Int):Void {
		if (provider != null) provider.onMove(delta);
		if (results.length == 0) return;
		selected += delta;
		if (selected < 0) selected = results.length - 1;
		if (selected >= results.length) selected = 0;
	}

	function accept(backwards:Bool):Void {
		var current = provider;
		if (current == null) return;
		var entry = selected >= 0 && selected < results.length ? results[selected] : null;
		input.remember();
		current.onAccept(entry, query, backwards);
	}

	function complete():Void {
		var current = provider;
		if (current == null) return;
		var entry = selected >= 0 && selected < results.length ? results[selected] : null;
		input.setText(current.onComplete(query, entry));
		changed();
	}

	public function draw(renderer:Renderer, theme:Theme, windowWidth:Int, windowHeight:Int):Void {
		var current = provider;
		if (!active || current == null) return;
		var width = commandWidth(windowWidth);
		var x = Std.int((windowWidth - width) / 2), y = 48, rowHeight = 26, visible = results.length;
		if (visible > 10) visible = 10;
		var height = 42 + visible * rowHeight;
		renderer.clip(0, 0, windowWidth, windowHeight);
		renderer.rect(0, 0, windowWidth, windowHeight, theme.overlay);
		renderer.rect(x - 2, y - 2, width + 4, height + 4, theme.border);
		renderer.rect(x, y, width, 40, theme.surfaceElevated);
		var inputX = x + 12, inputY = y + 11, promptWidth = renderer.textWidth(current.prompt),
			selectionStart = input.selection.start().column, selectionEnd = input.selection.end().column;
		if (selectionEnd > selectionStart) {
			var selectionX = inputX + promptWidth + renderer.textWidth(query.substring(0, selectionStart)),
				selectionWidth = renderer.textWidth(query.substring(selectionStart, selectionEnd));
			renderer.rect(selectionX, y + 5, selectionWidth, 28, theme.selection);
		}
		renderer.text(inputX, inputY, current.prompt + query, theme.caret);
		var caretX = inputX + promptWidth + renderer.textWidth(query.substring(0, input.selection.cursor.column));
		renderer.rect(caretX, y + 7, 2, 24, theme.caret);
		if (compositionText.length > 0) {
			var start = utf16Column(compositionText, compositionStart), end = utf16Column(compositionText, compositionStart + compositionLength);
			if (end > start) renderer.rect(caretX + renderer.textWidth(compositionText.substring(0, start)), y + 7,
				renderer.textWidth(compositionText.substring(start, end)), 24, theme.selection);
			renderer.text(caretX, inputY, compositionText, theme.caret);
			renderer.rect(caretX, y + 30, renderer.textWidth(compositionText), 1, theme.caret);
		}
		for (index in 0...visible) {
			var rowY = y + 42 + index * rowHeight, entry = results[index];
			if (index == selected) renderer.rect(x, rowY, width, rowHeight, theme.accent);
			var foreground = index == selected ? theme.editorBackground : theme.editorForeground;
			renderer.text(x + 12, rowY + 5, entry.label, foreground);
			if (entry.detail.length > 0) renderer.text(x + Std.int(width * 0.55), rowY + 5, entry.detail,
				index == selected ? theme.editorBackground : theme.foregroundMuted);
		}
	}

	static function commandWidth(windowWidth:Int):Int {
		var width = windowWidth - 80;
		if (width > 640) width = 640;
		if (width < 200) width = 200;
		return width;
	}

	static function utf16Column(value:String, characters:Int):Int {
		var column = 0, remaining = characters;
		while (column < value.length && remaining > 0) {
			var code = value.charCodeAt(column++);
			if (code >= 0xd800 && code <= 0xdbff && column < value.length) {
				var next = value.charCodeAt(column);
				if (next >= 0xdc00 && next <= 0xdfff) column++;
			}
			remaining--;
		}
		return column;
	}

	function filter():Void {
		var previousValue = selected >= 0 && selected < results.length ? results[selected].value : null;
		results.resize(0);
		if (provider == null) return;
		for (index in 0...provider.entries.length) {
			var entry = provider.entries[index];
			var score = fuzzyScore(entry.label, query);
			if (score >= 0) {
				entry.score = score;
				entry.order = index;
				results.push(entry);
			}
		}
		results.sort(function(left, right) {
			if (left.score != right.score) return right.score - left.score;
			var label = Reflect.compare(left.label.toLowerCase(), right.label.toLowerCase());
			return label != 0 ? label : left.order - right.order;
		});
		selected = 0;
		if (previousValue != null)
			for (index in 0...results.length) if (results[index].value == previousValue) selected = index;
	}

	public static function fuzzyScore(value:String, query:String):Int {
		if (query.length == 0) return 0;
		var text = value.toLowerCase(), needle = query.toLowerCase(), position = 0, score = 0, previous = -2;
		if (text == needle) return 100000;
		if (StringTools.startsWith(text, needle)) return 50000 - text.length;
		var slash = text.lastIndexOf("/"), base = slash < 0 ? text : text.substring(slash + 1);
		if (base == needle) return 90000;
		if (StringTools.startsWith(base, needle)) score += 30000;
		for (index in 0...needle.length) {
			var found = text.indexOf(needle.charAt(index), position);
			if (found < 0) return -1;
			score += found == previous + 1 ? 20 : 2;
			if (found == 0 || text.charAt(found - 1) == "/" || text.charAt(found - 1) == ":"
				|| text.charAt(found - 1) == "-" || text.charAt(found - 1) == "_") score += 12;
			previous = found;
			position = found + 1;
		}
		return score - text.length;
	}
}
