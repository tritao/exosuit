package testing.model;

import view.View;
import view.LayoutKind;

import completion.CompletionItem;
import platform.Platform;
import platform.TextInputArea;
import style.Theme;
import language.SignatureHelp;

/** Caret-anchored presentation shared by completion and language information. */
class ModelAnchoredPopup {
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
	var input:Null<String->Void>;
	var completionKey:Null<(Int, Int)->Bool>;

	public function new() {}

	public function openCompletion(anchor:TextInputArea, values:Array<CompletionItem>, accept:CompletionItem->Void, ?input:String->Void, ?key:(Int, Int)->Bool):Void {
		this.input = input;
		this.completionKey = key;
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
		accept = function(item) {};
		input = null;
		completionKey = null;
		items.resize(0);
		this.anchor = anchor;
		information = value;
		emphasized = "";
		visible = value.length > 0;
	}

	public function openSignature(anchor:TextInputArea, value:SignatureHelp):Void {
		accept = function(item) {};
		input = null;
		completionKey = null;
		items.resize(0);
		this.anchor = anchor;
		information = value.label + (value.documentation.length == 0 ? "" : "\n" + value.documentation);
		emphasized = value.activeParameter;
		visible = true;
	}

	public function close():Void {
		visible = false;
		items.resize(0);
		accept = function(item) {};
		input = null;
		completionKey = null;
	}

	public function textInput(text:String):Bool {
		if (!visible || items.length == 0 || input == null) return false;
		input(text);
		return true;
	}

	public function keyPressed(key:Int, modifiers:Int):Bool {
		if (!visible) return false;
		if (key == Platform.KEY_ESCAPE) { close(); return true; }
		if (items.length == 0) return false;
		if (completionKey != null && completionKey(key, modifiers)) return true;
		if (key == Platform.KEY_DOWN) { selected = (selected + 1) % items.length; return true; }
		if (key == Platform.KEY_UP) { selected = (selected + items.length - 1) % items.length; return true; }
		if (key == Platform.KEY_ENTER || key == Platform.KEY_TAB) {
			var item = items[selected];
			var complete = accept;
			close();
			complete(item);
			return true;
		}
		return false;
	}

}
