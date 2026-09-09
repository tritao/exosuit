package view;

import feedback.Problem;
import feedback.ProblemRegistry;
import renderer.Renderer;
import style.Theme;

class ProblemsView extends View {
	final problems:ProblemRegistry;
	final renderer:Renderer;
	final theme:Theme;
	final activateProblem:Problem->Void;
	var x:Int = 0;
	var y:Int = 0;
	var width:Int;
	var height:Int;
	var selected:Int = 0;
	var scrollRow:Int = 0;

	public function new(problems:ProblemRegistry, renderer:Renderer, theme:Theme, width:Int, height:Int, activateProblem:Problem->Void) {
		super("Problems");
		this.problems = problems; this.renderer = renderer; this.theme = theme;
		this.width = width; this.height = height; this.activateProblem = activateProblem;
	}

	override public function setBounds(x:Int, y:Int, width:Int, height:Int):Void {
		this.x = x; this.y = y; this.width = width; this.height = height;
	}
	override public function resize(width:Int, height:Int):Void { this.width = width; this.height = height; }
	override public function moveVertical(delta:Int, extend:Bool):Void {
		var values = problems.values(); if (values.length == 0) return;
		selected += delta; if (selected < 0) selected = 0; if (selected >= values.length) selected = values.length - 1;
		ensureVisible();
	}
	override public function insertNewline():Bool { activateSelected(); return true; }
	override public function mouseDown(button:Int, pointerX:Int, pointerY:Int, clicks:Int = 1):Void {
		if (button != 1 || pointerY < y + editor.EditorView.HEADER_HEIGHT) return;
		selected = scrollRow + Std.int((pointerY - y - editor.EditorView.HEADER_HEIGHT) / renderer.lineHeight);
		var values = problems.values(); if (selected >= 0 && selected < values.length) activateProblem(values[selected]);
	}
	override public function wheel(vertical:Int, horizontal:Int):Void { scrollRow -= Std.int(vertical * 3 / 100); clamp(); }
	override public function draw():Void {
		var values = problems.values(); clamp();
		renderer.rect(x, y, width, height, theme.editorBackground);
		renderer.rect(x, y, width, editor.EditorView.HEADER_HEIGHT, theme.surfaceElevated);
		renderer.text(x + 12, y + 13, "Problems (" + values.length + ")", theme.foregroundMuted);
		var visible = Std.int((height - editor.EditorView.HEADER_HEIGHT) / renderer.lineHeight) + 1, end = scrollRow + visible;
		if (end > values.length) end = values.length;
		for (index in scrollRow...end) {
			var problem = values[index], rowY = y + editor.EditorView.HEADER_HEIGHT + (index - scrollRow) * renderer.lineHeight;
			if (index == selected) renderer.rect(x, rowY, width, renderer.lineHeight, theme.surfaceActive);
			var color = problem.severity <= 1 ? theme.error : problem.severity == 2 ? theme.warning : theme.foregroundMuted;
			renderer.text(x + 8, rowY, problem.message + "  " + problem.path + ":" + (problem.line + 1), color);
		}
	}
	function activateSelected():Void { var values = problems.values(); if (selected >= 0 && selected < values.length) activateProblem(values[selected]); }
	function ensureVisible():Void { var visible = Std.int((height - editor.EditorView.HEADER_HEIGHT) / renderer.lineHeight); if (selected < scrollRow) scrollRow = selected; if (selected >= scrollRow + visible) scrollRow = selected - visible + 1; clamp(); }
	function clamp():Void { var maximum = problems.values().length - Std.int((height - editor.EditorView.HEADER_HEIGHT) / renderer.lineHeight); if (maximum < 0) maximum = 0; if (scrollRow < 0) scrollRow = 0; if (scrollRow > maximum) scrollRow = maximum; }
}
