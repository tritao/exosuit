package ui;

import Canvas;
import Color;
import FontCollection;
import LayoutAxis;
import LayoutStyle;
import ParagraphStyle;
import Rect;
import TextLayout;
import TextStyle;
import TextWrap;
import haxe.io.Bytes;
import nativekit.ui.core.BuildContext;
import nativekit.ui.core.CachePolicy;
import nativekit.ui.core.RenderNode;
import nativekit.ui.core.UiEvent;
import nativekit.ui.core.UiEventKind;
import nativekit.ui.core.UiKey;
import nativekit.ui.core.View;
import nativekit.ui.widgets.CanvasView;
import nativekit.ui.widgets.layout.Stack;
import nativekit.ui.widgets.layout.StackChild;
import sys.FileSystem;
import terminalsession.TerminalSession;

/** Retained terminal rows; each row has its own raster cache and text layout. */
class TerminalPane implements View {
	public final session:TerminalSession;
	final requestFrame:Void->Void;
	final fonts:FontCollection;
	final layouts:Array<TextLayout> = [];
	final texts:Array<String> = [];
	final revisions:Array<Int> = [];
	final foreground = Color.rgba(0.87, 0.89, 0.91, 1.0);
	final background = Color.rgba(0.06, 0.07, 0.09, 1.0);
	final cellWidth:Float;
	final rowHeight:Float;
	var viewportWidth:Float = 0.0;
	var viewportHeight:Float = 0.0;
	var focusRequested:Bool = false;
	var closed:Bool = false;

	public function new(session:TerminalSession, requestFrame:Void->Void) {
		this.session = session;
		this.requestFrame = requestFrame;
		fonts = FontCollection.create();
		var mono = Sys.getEnv("EXOSUIT_TERMINAL_FONT");
		if (mono == null || mono.length == 0)
			mono = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf";
		if (FileSystem.exists(mono)) fonts.add(mono);
		fonts.addSystemFallbacks();
		var probe = TextLayout.create(fonts, "M", 64.0, new TextStyle(14.0), new ParagraphStyle(TextWrap.None));
		var metrics = probe.measure();
		cellWidth = Math.max(1.0, metrics.width);
		rowHeight = Math.max(1.0, Math.ceil(metrics.height + 2.0));
		probe.dispose();
		refreshRows(true);
	}

	public function poll():Void {
		if (closed) return;
		session.pollEvents();
		refreshRows(false);
	}

	function refreshRows(force:Bool):Void {
		var emulator = session.emulator;
		emulator.snapshot();
		var count = emulator.rows();
		while (layouts.length > count) {
			layouts.pop().dispose();
			texts.pop();
			revisions.pop();
		}
		while (layouts.length < count) {
			var layout = TextLayout.create(fonts, "", 8192.0, new TextStyle(14.0), new ParagraphStyle(TextWrap.None));
			layout.setColor(foreground);
			layouts.push(layout);
			texts.push("");
			revisions.push(0);
			force = true;
		}
		for (row in 0...count) {
			if (!force && !emulator.rowChanged(row)) continue;
			var next = emulator.rowText(row);
			if (force || next != texts[row]) {
				layouts[row].setText(next);
				texts[row] = next;
				revisions[row]++;
			}
		}
	}

	public function build(context:BuildContext):RenderNode {
		var fill = new LayoutStyle();
		fill.width = LayoutAxis.grow();
		fill.height = LayoutAxis.grow();
		var backdrop = new CanvasView("terminal-backdrop", function(canvas:Canvas, geometry) {
			canvas.fillRectIfPositive(new Rect(0.0, 0.0, geometry.width, geometry.height), background);
			resizeToViewport(geometry.width, geometry.height);
		}, fill, "Terminal", true);
		var layers:Array<StackChild> = [new StackChild("background", backdrop, 0.0, 0.0, 0,
			LayoutAxis.grow(), LayoutAxis.grow())];
		for (row in 0...layouts.length) {
			var index = row;
			var rowStyle = new LayoutStyle();
			rowStyle.width = LayoutAxis.grow();
			rowStyle.height = LayoutAxis.fixed(rowHeight);
			var key = 'terminal-row-$index-${revisions[index]}-${Std.int(viewportWidth)}';
			var view = new CanvasView('terminal-row-$index', function(canvas:Canvas, geometry) {
				canvas.fillRectIfPositive(new Rect(0.0, 0.0, geometry.width, geometry.height), background);
				canvas.drawText(layouts[index], 8.0, 0.0);
			}, rowStyle, null, false, CachePolicy.Raster, key);
			layers.push(new StackChild('row-$index', view, 0.0, 4.0 + index * rowHeight,
				1, LayoutAxis.grow(), LayoutAxis.fixed(rowHeight)));
		}
		var node = new Stack("terminal-pane", layers, fill).build(context);
		node.focusable = true;
		node.on(UiEventKind.PointerDown, function(_) context.requestFocus(node.id));
		node.on(UiEventKind.TextInput, function(event:UiEvent) {
			if (event.text != null && event.text.length > 0) {
				session.write(Bytes.ofString(event.text));
				event.preventDefault();
			}
		});
		node.on(UiEventKind.KeyDown, handleKey);
		if (!focusRequested) focusRequested = context.requestFocus(node.id);
		return node;
	}

	function handleKey(event:UiEvent):Void {
		var bytes = switch event.key {
			case UiKey.Enter: "\r";
			case UiKey.Backspace: "\x7f";
			case UiKey.Tab: "\t";
			default: null;
		};
		if (bytes != null) {
			session.write(Bytes.ofString(bytes));
			event.preventDefault();
		}
	}

	function resizeToViewport(width:Float, height:Float):Void {
		if (closed || width <= 0.0 || height <= 0.0) return;
		if (width == viewportWidth && height == viewportHeight) return;
		viewportWidth = width;
		viewportHeight = height;
		var columns = Std.int(Math.max(1.0, Math.min(512.0, Math.floor((width - 16.0) / cellWidth))));
		var rows = Std.int(Math.max(1.0, Math.min(256.0, Math.floor((height - 8.0) / rowHeight))));
		if (columns != session.emulator.columns() || rows != session.emulator.rows()) {
			session.resize(columns, rows);
			requestFrame();
		}
	}

	public function close():Void {
		if (closed) return;
		closed = true;
		for (layout in layouts) layout.dispose();
		layouts.resize(0);
		fonts.dispose();
		session.close();
	}
}
