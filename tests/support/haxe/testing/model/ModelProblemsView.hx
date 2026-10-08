package testing.model;

import view.View;
import view.LayoutKind;

import feedback.Problem;
import feedback.ProblemRegistry;
import style.Theme;

class ModelProblemsView extends View {
	final problems:ProblemRegistry;
	final metrics:testing.model.ModelTextMetrics;
	final theme:Theme;
	final activateProblem:Problem->Void;
	var x:Int = 0;
	var y:Int = 0;
	var width:Int;
	var height:Int;
	var selected:Int = 0;
	var scrollRow:Int = 0;

	public function new(problems:ProblemRegistry, metrics:testing.model.ModelTextMetrics, theme:Theme, width:Int, height:Int, activateProblem:Problem->Void) {
		super("Problems");
		this.problems = problems; this.metrics = metrics; this.theme = theme;
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
	override public function insertNewline(tabWidth:Int = 0, insertSpaces:Bool = true):Bool { activateSelected(); return true; }
	override public function mouseDown(button:Int, pointerX:Int, pointerY:Int, clicks:Int = 1):Void {
		if (button != 1 || pointerY < y + testing.model.EditorViewportModel.HEADER_HEIGHT) return;
		selected = scrollRow + Std.int((pointerY - y - testing.model.EditorViewportModel.HEADER_HEIGHT) / metrics.lineHeight);
		var values = problems.values(); if (selected >= 0 && selected < values.length) activateProblem(values[selected]);
	}
	override public function wheel(vertical:Int, horizontal:Int):Void { scrollRow -= Std.int(vertical * 3 / 100); clamp(); }

	function activateSelected():Void { var values = problems.values(); if (selected >= 0 && selected < values.length) activateProblem(values[selected]); }
	function ensureVisible():Void { var visible = Std.int((height - testing.model.EditorViewportModel.HEADER_HEIGHT) / metrics.lineHeight); if (selected < scrollRow) scrollRow = selected; if (selected >= scrollRow + visible) scrollRow = selected - visible + 1; clamp(); }
	function clamp():Void { var maximum = problems.values().length - Std.int((height - testing.model.EditorViewportModel.HEADER_HEIGHT) / metrics.lineHeight); if (maximum < 0) maximum = 0; if (scrollRow < 0) scrollRow = 0; if (scrollRow > maximum) scrollRow = maximum; }
}
