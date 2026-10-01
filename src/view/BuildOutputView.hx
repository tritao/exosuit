package view;

import build.BuildOutput;
import editor.EditorView;
import style.Theme;

class BuildOutputView extends View {
	final output:BuildOutput;
	final renderer:renderer.Renderer;
	final theme:Theme;
	final activateDiagnostic:build.BuildDiagnostic->Void;
	var x:Int = 0;
	var y:Int = 0;
	var width:Int;
	var height:Int;
	var scrollRow:Int = 0;

	public function new(output:BuildOutput, renderer:renderer.Renderer, theme:Theme, width:Int, height:Int,
			activateDiagnostic:build.BuildDiagnostic->Void) {
		super("Build Output");
		this.output = output;
		this.renderer = renderer;
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
		if (button != 1 || pointerY < y + EditorView.HEADER_HEIGHT) return;
		var row = scrollRow + Std.int((pointerY - y - EditorView.HEADER_HEIGHT) / renderer.lineHeight);
		if (row < 0 || row >= output.lines.length) return;
		var diagnostic = output.lines[row].diagnostic;
		if (diagnostic != null) activateDiagnostic(diagnostic);
	}

	override public function draw():Void {
		clampScroll();
		renderer.rect(x, y, width, height, theme.editorBackground);
		renderer.rect(x, y, width, EditorView.HEADER_HEIGHT, theme.surfaceElevated);
		renderer.text(x + 12, y + 13, title, theme.foregroundMuted);
		renderer.clip(x, y + EditorView.HEADER_HEIGHT, width, height - EditorView.HEADER_HEIGHT);
		var visible = Std.int((height - EditorView.HEADER_HEIGHT) / renderer.lineHeight) + 1, end = scrollRow + visible;
		if (end > output.lines.length) end = output.lines.length;
		for (row in scrollRow...end) {
			var line = output.lines[row], color = line.diagnostic == null ? theme.editorForeground : theme.accent;
			renderer.text(x + 8, y + EditorView.HEADER_HEIGHT + (row - scrollRow) * renderer.lineHeight, line.text, color);
		}
		renderer.clip(x, y, width, height);
	}

	function clampScroll():Void {
		var visible = Std.int((height - EditorView.HEADER_HEIGHT) / renderer.lineHeight), maximum = output.lines.length - visible;
		if (maximum < 0) maximum = 0;
		if (scrollRow < 0) scrollRow = 0;
		if (scrollRow > maximum) scrollRow = maximum;
	}
}
