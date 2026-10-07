package ui;

import editor.SyntaxPresentation;
import editor.TextBuffer;
import haxeon.editor.TextDocument;
import haxeon.ui.Color;
import haxeon.ui.TextColorRange;
import style.Theme;
import syntax.Highlighter;
import syntax.SyntaxDefinition;
import syntax.SyntaxRegistry;

/** Syntax and retained text state for one immutable remote file snapshot. */
class WorkspaceFileTextModel {
	public final buffer:TextBuffer;
	public final syntax:SyntaxDefinition;
	public final highlighter:Highlighter;
	public final foregroundProvider:(Int, Int)->Array<TextColorRange>;
	public var presentationRevision(default, null):Int = 0;
	var editorTheme:Theme;
	var previousColors:Array<Int> = [];

	public function new(path:String, contents:String, syntaxes:SyntaxRegistry, editorTheme:Theme) {
		if (path == null || contents == null || syntaxes == null || editorTheme == null)
			throw "Invalid workspace file text model";
		buffer = new TextBuffer(contents);
		syntax = syntaxes.find(path, contents.substr(0, 128));
		highlighter = new Highlighter(buffer, syntax);
		foregroundProvider = function(start, end) return provideForeground(start, end);
		updateTheme(editorTheme);
	}

	public function document():TextDocument return buffer.document;

	public function updateTheme(theme:Theme):Void {
		var colors = [theme.editorForeground];
		for (kind in 0...8) colors.push(theme.tokenColor(kind));
		var changed = colors.length != previousColors.length;
		if (!changed) for (index in 0...colors.length)
			if (colors[index] != previousColors[index]) changed = true;
		if (changed) {
			previousColors = colors;
			presentationRevision++;
		}
		editorTheme = theme;
	}

	function provideForeground(start:Int, end:Int):Array<TextColorRange> {
		return [for (range in SyntaxPresentation.foregroundText(buffer.document, highlighter, editorTheme, start, end))
			new TextColorRange(range.start, range.end, color(range.color))];
	}

	static function color(value:Int):Color
		return Color.fromBytes((value >>> 24) & 255, (value >>> 16) & 255,
			(value >>> 8) & 255, value & 255);
}
