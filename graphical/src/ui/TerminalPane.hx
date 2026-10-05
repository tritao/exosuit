package ui;

import Canvas;
import Color;
import FontCollection;
import LayoutAxis;
import LayoutStyle;
import ParagraphStyle;
import Rect;
import TextLayout;
import TextColorRange;
import TextStyle;
import TextWrap;
import haxe.io.Bytes;
import nativekit.ui.core.BuildContext;
import nativekit.ui.core.CachePolicy;
import nativekit.ui.core.RenderNode;
import nativekit.ui.core.UiEvent;
import nativekit.ui.core.UiEventKind;
import nativekit.ui.core.UiKey;
import nativekit.ui.core.UiModifier;
import nativekit.ui.core.View;
import nativekit.ui.widgets.CanvasView;
import nativekit.ui.widgets.layout.Stack;
import nativekit.ui.widgets.layout.StackChild;
import sys.FileSystem;
import terminalsession.TerminalSession;
import terminalkit.Cell;

private typedef TerminalBackground = {start:Int, end:Int, color:Color};

/** Retained terminal rows; each row has its own raster cache and text layout. */
class TerminalPane implements TerminalPanel {
	public final session:TerminalSession;
	final requestFrame:Void->Void;
	final fonts:FontCollection;
	final layouts:Array<TextLayout> = [];
	final texts:Array<String> = [];
	final revisions:Array<Int> = [];
	final backgrounds:Array<Array<TerminalBackground>> = [];
	final palette:TerminalPalette;
	final foreground:Color;
	final background:Color;
	var cellWidth:Float;
	var rowHeight:Float;
	var fontSize:Float;
	var fontRevision:Int = 0;
	var viewportWidth:Float = 0.0;
	var viewportHeight:Float = 0.0;
	var resolvedWidth:Float = 0.0;
	var resolvedHeight:Float = 0.0;
	var focusRequested:Bool = false;
	var focused:Bool = false;
	var closed:Bool = false;
	var cursorRow:Int = -1;
	var cursorColumn:Int = -1;
	var cursorMode:Int = 1;

	public static function open(cwd:String, requestFrame:Void->Void, palette:TerminalPalette):TerminalPanel {
		var profile = terminalsession.TerminalProfile.shell(cwd);
		var backend = terminalsession.LocalPtyBackend.spawn(profile, 80, 24);
		try {
			var session = new TerminalSession(backend, terminalkit.Emulator.open(80, 24));
			try {
				return new TerminalPane(session, requestFrame, palette);
			} catch (error:Dynamic) {
				session.close();
				throw error;
			}
		} catch (error:Dynamic) {
			backend.close();
			throw error;
		}
	}

	public function status():String
		return session.status;

	public function columns():Int
		return session.emulator.columns();

	public function rows():Int
		return session.emulator.rows();

	public function new(session:TerminalSession, requestFrame:Void->Void, palette:TerminalPalette) {
		this.session = session;
		this.requestFrame = requestFrame;
		this.palette = palette;
		foreground = palette.foreground;
		background = palette.background;
		fonts = FontCollection.create();
		var mono = Sys.getEnv("EXOSUIT_TERMINAL_FONT");
		if (mono == null || mono.length == 0)
			mono = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf";
		if (FileSystem.exists(mono)) fonts.add(mono);
		fonts.addSystemFallbacks();
		updateFontSize();
		refreshRows(true);
	}

	public function poll():Void {
		if (closed) return;
		if (fontSize != palette.fontSize) {
			updateFontSize();
			resizeToViewport(resolvedWidth, resolvedHeight);
			requestFrame();
		}
		session.pollEvents();
		refreshRows(false);
	}

	function updateFontSize():Void {
		fontSize = palette.fontSize;
		var probe = TextLayout.create(fonts, "M", 64.0, new TextStyle(fontSize), new ParagraphStyle(TextWrap.None));
		var metrics = probe.measure();
		cellWidth = Math.max(1.0, metrics.width);
		rowHeight = Math.max(1.0, Math.ceil(metrics.height + 2.0));
		probe.dispose();
		for (revision in revisions) if (revision >= fontRevision) fontRevision = revision + 1;
		for (layout in layouts) layout.dispose();
		viewportWidth = -1; viewportHeight = -1;
		layouts.resize(0); texts.resize(0); revisions.resize(0); backgrounds.resize(0);
	}

	function refreshRows(force:Bool):Void {
		var emulator = session.emulator;
		emulator.snapshot();
		var count = emulator.rows();
		while (layouts.length > count) {
			layouts.pop().dispose();
			texts.pop();
			revisions.pop();
			backgrounds.pop();
		}
		while (layouts.length < count) {
			var layout = TextLayout.create(fonts, "", 8192.0, new TextStyle(fontSize), new ParagraphStyle(TextWrap.None));
			layout.setColor(foreground);
			layouts.push(layout);
			texts.push("");
			revisions.push(fontRevision);
			backgrounds.push([]);
			force = true;
		}
		for (row in 0...count) {
			if (!force && !emulator.rowChanged(row)) continue;
			var cells = emulator.rowCells(row);
			var buffer = new StringBuf();
			var ranges:Array<TextColorRange> = [];
			var fills:Array<TerminalBackground> = [];
			var offset = 0;
			for (column in 0...cells.length) {
				var cell:Cell = cells[column];
				if (cell.width == 0) continue;
				var content = cell.text.length == 0 ? " " : cell.text;
				buffer.add(content);
				var count = codepoints(content);
				var fg = haxe.Int64.toInt(cell.style);
				var bg = haxe.Int64.toInt(cell.style >>> 32);
				if ((fg & 3) != 0) ranges.push(new TextColorRange(offset, offset + count,
					TerminalColors.decode(fg, foreground, palette, false)));
				if ((bg & 3) != 0) fills.push({start: column, end: column + cell.width,
					color: TerminalColors.decode(bg, background, palette, true)});
				offset += count;
			}
			var next = buffer.toString();
			if (force || next != texts[row] || emulator.rowChanged(row)) {
				layouts[row].setText(next);
				layouts[row].setColorRanges(ranges);
				texts[row] = next;
				backgrounds[row] = fills;
				revisions[row]++;
			}
		}
		var cursor = emulator.cursor();
		if (cursorRow != cursor.row || cursorColumn != cursor.column || cursorMode != cursor.mode) {
			if (cursorRow >= 0 && cursorRow < revisions.length) revisions[cursorRow]++;
			cursorRow = cursor.row;
			cursorColumn = cursor.column;
			cursorMode = cursor.mode;
			if (cursorRow >= 0 && cursorRow < revisions.length) revisions[cursorRow]++;
		}
	}

	static function codepoints(value:String):Int {
		var bytes = Bytes.ofString(value);
		var count = 0;
		for (i in 0...bytes.length) if ((bytes.get(i) & 0xc0) != 0x80) count++;
		return count;
	}

	public function build(context:BuildContext):RenderNode {
		// Resize before creating row painters; painting must not invalidate this frame.
		resizeToViewport(resolvedWidth, resolvedHeight);
		var fill = new LayoutStyle();
		fill.width = LayoutAxis.grow();
		fill.height = LayoutAxis.grow();
		var backdrop = new CanvasView("terminal-backdrop", function(canvas:Canvas, geometry) {
			canvas.fillRectIfPositive(new Rect(0.0, 0.0, geometry.width, geometry.height), background);
			if (focused) canvas.fillRectIfPositive(new Rect(0.0, 0.0, geometry.width, 2.0), palette.cursor);
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
				for (fill in backgrounds[index]) canvas.fillRectIfPositive(new Rect(8.0 + fill.start * cellWidth,
					0.0, (fill.end - fill.start) * cellWidth, rowHeight), fill.color);
				canvas.drawText(layouts[index], 8.0, 0.0);
				if (index == cursorRow && cursorMode != 1)
					canvas.fillRectIfPositive(new Rect(8.0 + cursorColumn * cellWidth, rowHeight - 2.0,
						cellWidth, 2.0), palette.cursor);
			}, rowStyle, null, false, CachePolicy.Raster, key);
			layers.push(new StackChild('row-$index', view, 0.0, 4.0 + index * rowHeight,
				1, LayoutAxis.grow(), LayoutAxis.fixed(rowHeight)));
		}
		var node = new Stack("terminal-pane", layers, fill).build(context);
		node.onResolved(function(_) {
			var bounds = node.globalBounds();
			if (bounds.width != resolvedWidth || bounds.height != resolvedHeight) {
				resolvedWidth = bounds.width;
				resolvedHeight = bounds.height;
				requestFrame();
			}
		});
		node.focusable = true;
		node.on(UiEventKind.PointerDown, function(_) context.requestFocus(node.id));
		node.on(UiEventKind.TextInput, function(event:UiEvent) {
			if (event.text != null && event.text.length > 0) {
				session.write(Bytes.ofString(event.text));
				event.preventDefault();
			}
		});
		node.on(UiEventKind.KeyDown, handleKey);
		node.on(UiEventKind.KeyRepeat, handleKey);
		node.on(UiEventKind.Focus, function(_) {
			focused = true;
			session.emulator.focus(true);
			requestFrame();
		});
		node.on(UiEventKind.FocusLost, function(_) {
			focused = false;
			session.emulator.focus(false);
			requestFrame();
		});
		node.on(UiEventKind.Scroll, function(event:UiEvent) {
			var current = session.emulator.scrollback(-1).current;
			var step = Std.int(Math.round(event.deltaY / rowHeight * 3.0));
			if (step == 0) step = event.deltaY > 0 ? 1 : -1;
			session.emulator.scrollback(current + step);
			refreshRows(true);
			requestFrame();
			event.preventDefault();
		});
		if (!focusRequested) focusRequested = context.requestFocus(node.id);
		return node;
	}

	function handleKey(event:UiEvent):Void {
		var name = switch event.key {
			case UiKey.Enter: "enter";
			case UiKey.Backspace: "backspace";
			case UiKey.Tab: "tab";
			case UiKey.Escape: "escape";
			case UiKey.Up: "up";
			case UiKey.Down: "down";
			case UiKey.Left: "left";
			case UiKey.Right: "right";
			case UiKey.Home: "home";
			case UiKey.End: "end";
			case UiKey.PageUp: "pageup";
			case UiKey.PageDown: "pagedown";
			case UiKey.Delete: "delete";
			default: null;
		};
		if (name != null && session.emulator.key(name, event.modifiers)) {
			session.pollEvents();
			event.preventDefault();
			return;
		}
		var bytes = switch event.key {
			case UiKey.Enter: "\r";
			case UiKey.Backspace: "\x7f";
			case UiKey.Tab: "\t";
			case UiKey.Escape: "\x1b";
			case UiKey.Up: "\x1b[A";
			case UiKey.Down: "\x1b[B";
			case UiKey.Right: "\x1b[C";
			case UiKey.Left: "\x1b[D";
			case UiKey.Home: "\x1b[H";
			case UiKey.End: "\x1b[F";
			case UiKey.Delete: "\x1b[3~";
			case UiKey.PageUp: "\x1b[5~";
			case UiKey.PageDown: "\x1b[6~";
			default: null;
		};
		if (bytes == null && (event.modifiers & UiModifier.Control) != 0) {
			if (event.key >= UiKey.A && event.key <= UiKey.Z)
				bytes = String.fromCharCode(event.key - UiKey.A + 1);
		}
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
			// Re-render all rows now; waiting for PTY output leaves stale/missing rows while dragging.
			refreshRows(true);
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
