package commandview;

import platform.Platform;
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

	public var onChanged:Void->Void = function() {};
	public function new() { input.onAsyncEdit = function() { if (active) changed(); }; }

	function get_query():String return input.text;

	public function open(provider:CommandViewProvider):Void {
		this.provider = provider;
		results.resize(0);
		input.reset();
		clearComposition();
		selected = 0;
		active = true;
		provider.onQuery(query);
		filter();
	}

	public function close(cancel:Bool = false):Void {
		var current = provider;
		input.invalidateClipboard();
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

	public function textInputArea(measure:String->Int, windowWidth:Int):TextInputArea {
		var width = commandWidth(windowWidth), x = Std.int((windowWidth - width) / 2), inputX = x + 12,
			promptWidth = provider == null ? 0 : measure(provider.prompt),
			caretX = inputX + promptWidth + measure(query.substring(0, input.selection.cursor.column));
		return new TextInputArea(caretX, 24, 2, 24);
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
		else if (key == Platform.KEY_V && (modifiers & Platform.MOD_CTRL) != 0) input.paste();
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
		onChanged();
	}

	function move(delta:Int):Void {
		if (provider != null) provider.onMove(delta);
		if (results.length == 0) return;
		selected += delta;
		if (selected < 0) selected = results.length - 1;
		if (selected >= results.length) selected = 0;
	}

	public function mouseMove(pointerX:Int, pointerY:Int, windowWidth:Int, windowHeight:Int):Void {
		var index = resultAt(pointerX, pointerY, windowWidth, windowHeight);
		if (index >= 0) select(index);
	}

	public function mouseDown(button:Int, pointerX:Int, pointerY:Int, windowWidth:Int, windowHeight:Int):Bool {
		if (!active || button != Platform.MOUSE_LEFT) return false;
		var index = resultAt(pointerX, pointerY, windowWidth, windowHeight);
		if (index < 0) return false;
		select(index);
		accept(false);
		return true;
	}

	public function wheel(vertical:Int):Void {
		if (!active || results.length == 0 || vertical == 0) return;
		var amount = Std.int((vertical < 0 ? -vertical : vertical) / 100);
		if (amount < 1) amount = 1;
		var target = selected + (vertical < 0 ? amount : -amount);
		if (target < 0) target = 0;
		if (target >= results.length) target = results.length - 1;
		select(target);
	}

	function select(index:Int):Void {
		if (index == selected || index < 0 || index >= results.length) return;
		var delta = index - selected;
		selected = index;
		if (provider != null) provider.onMove(delta);
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



	function visibleSectionCount(start:Int, visible:Int):Int {
		if (query.length > 0) return 0;
		var count = 0, previous = "";
		for (index in 0...visible) {
			var section = results[start + index].section;
			if (section.length > 0 && section != previous) count++;
			previous = section;
		}
		return count;
	}

	public function visibleStart(visible:Int):Int {
		if (visible <= 0 || selected < visible) return 0;
		var start = selected - visible + 1, maximum = results.length - visible;
		return start > maximum ? maximum : start;
	}

	public function resultAt(pointerX:Int, pointerY:Int, windowWidth:Int, windowHeight:Int):Int {
		if (!active) return -1;
		var width = commandWidth(windowWidth), x = Std.int((windowWidth - width) / 2), y = 16,
			visible = visibleCount(windowHeight), first = visibleStart(visible), rowY = y + 44, previousSection = "";
		if (pointerX < x || pointerX >= x + width) return -1;
		for (offset in 0...visible) {
			var index = first + offset, entry = results[index];
			if (query.length == 0 && entry.section.length > 0 && entry.section != previousSection) rowY += 22;
			previousSection = entry.section;
			if (pointerY >= rowY && pointerY < rowY + 28) return index;
			rowY += 28;
		}
		return -1;
	}

	function visibleCount(windowHeight:Int):Int {
		var visible = Std.int((windowHeight - 16 - 90) / 28);
		if (visible < 1) visible = 1;
		if (visible > 12) visible = 12;
		if (visible > results.length) visible = results.length;
		return visible;
	}

	static function commandWidth(windowWidth:Int):Int {
		var width = Std.int(windowWidth * 0.72);
		if (width > 820) width = 820;
		if (width > windowWidth - 32) width = windowWidth - 32;
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
			if (score < 0) score = fuzzyScore(entry.searchText, query);
			if (score >= 0) {
				entry.score = score;
				entry.order = index;
				results.push(entry);
			}
		}
		results.sort(function(left, right) {
			if (left.score != right.score) return right.score - left.score;
			if (query.length == 0) return left.order - right.order;
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
