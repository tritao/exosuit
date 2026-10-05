package testing.model;

import view.View;
import view.LayoutKind;

import build.BuildOutput;
import testing.model.EditorViewportModel;
import style.Theme;

class ModelBuildOutputView extends View {
	final output:BuildOutput;
	final metrics:testing.model.ModelTextMetrics;
	final theme:Theme;
	final activateDiagnostic:build.BuildDiagnostic->Void;
	var x:Int = 0;
	var y:Int = 0;
	var width:Int;
	var height:Int;
	var scrollRow:Int = 0;

	public function new(output:BuildOutput, metrics:testing.model.ModelTextMetrics, theme:Theme, width:Int, height:Int,
			activateDiagnostic:build.BuildDiagnostic->Void) {
		super("Build Output");
		this.output = output;
		this.metrics = metrics;
		this.theme = theme;
		this.width = width;
		this.height = height;
		this.activateDiagnostic = activateDiagnostic;
	}

	override public function setBounds(x:Int, y:Int, width:Int, height:Int):Void {
		this.x = x;
		this.y = y;
		this.width = width;
		this.height = height;
	}

	override public function resize(width:Int, height:Int):Void {
		this.width = width;
		this.height = height;
	}

	override public function wheel(vertical:Int, horizontal:Int):Void {
		scrollRow -= Std.int(vertical * 3 / 100);
		clampScroll();
	}

	override public function mouseDown(button:Int, pointerX:Int, pointerY:Int, clicks:Int = 1):Void {
		if (button != 1 || pointerY < y + EditorViewportModel.HEADER_HEIGHT) return;
		var row = scrollRow + Std.int((pointerY - y - EditorViewportModel.HEADER_HEIGHT) / metrics.lineHeight);
		if (row < 0 || row >= output.lines.length) return;
		var diagnostic = output.lines[row].diagnostic;
		if (diagnostic != null) activateDiagnostic(diagnostic);
	}

	function clampScroll():Void {
		var visible = Std.int((height - EditorViewportModel.HEADER_HEIGHT) / metrics.lineHeight), maximum = output.lines.length - visible;
		if (maximum < 0) maximum = 0;
		if (scrollRow < 0) scrollRow = 0;
		if (scrollRow > maximum) scrollRow = maximum;
	}
}
