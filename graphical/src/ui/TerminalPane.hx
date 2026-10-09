package ui;

import haxeon.ui.Canvas;
import haxeon.ui.Color;
import haxeon.ui.FontCollection;
import haxeon.ui.FontFamily;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.ParagraphStyle;
import haxeon.ui.Rect;
import haxeon.ui.TextLayout;
import haxeon.ui.TextColorRange;
import haxeon.ui.TextStyle;
import haxeon.ui.TextWrap;
import haxe.io.Bytes;
import haxeon.ui.core.BuildContext;
import haxeon.platform.NativeKitEventValue.NativeKitTextEdit;
import nativekit.ffi.NativeKitTypes.TextEditAction;
import haxeon.ui.widgets.text.TextInputWindow;
import haxeon.ui.core.CachePolicy;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiEvent;
import haxeon.ui.core.UiEventKind;
import haxeon.ui.core.UiKey;
import haxeon.ui.core.UiModifier;
import haxeon.ui.core.View;
import haxeon.ui.widgets.CanvasView;
import haxeon.ui.widgets.layout.Stack;
import haxeon.ui.widgets.layout.StackChild;
import sys.FileSystem;
import terminalsession.TerminalSession;
import terminalkit.Cell;

private typedef TerminalBackground = {start:Int, end:Int, color:Color};

/** Retained terminal rows; each row has its own raster cache and text layout. */
class TerminalPane implements TerminalPanel {
	static inline final CONTROL_BAR_HEIGHT:Float = 26.0;
	public final session:TerminalSession;
	final requestFrame:Void->Void;
	final fonts:FontCollection;
	final layouts:Array<TextLayout> = [];
	final texts:Array<String> = [];
	final revisions:Array<Int> = [];
	final backgrounds:Array<Array<TerminalBackground>> = [];
	final palette:TerminalPalette;
	final ownsFonts:Bool;
	final remoteBackend:Null<workspace.client.RpcTerminalBackend>;
	var controlLayout:Null<TextLayout>;
	var controlActionLayout:Null<TextLayout>;
	var controlStatusText:String = "";
	var controlActionText:String = "";
	var foreground:Color;
	var background:Color;
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
	var focusGeneration:Int = 0;
	var closed:Bool = false;
	var selectionPointer:Int = -1;
	var selectionColumn:Int = 0;
	var selectionRow:Int = 0;
	var selectionMoved:Bool = false;
	var hasSelection:Bool = false;
	var mouseButton:Int = -1;
	var mousePointer:Int = -1;
	var controlPointer:Int = -1;
	var cursorRow:Int = -1;
	var cursorColumn:Int = -1;
	var cursorMode:Int = 1;
	var cursorOutlineColor:Color;
	var cursorOutlineWidth:Int = 1;

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

	public static function openRemote(provider:Void->Null<workspace.client.WorkspaceRpcEndpoint>, id:String, cwd:String, restored:Bool,
		requestFrame:Void->Void, palette:TerminalPalette, ?group:String, ?directory:String, ?providedFonts:FontCollection, autoClaimControl:Bool = false):TerminalPanel {
		var backend = new workspace.client.RpcTerminalBackend(provider,id,cwd,!restored,group,directory,autoClaimControl,true);
		var session = new TerminalSession(backend,terminalkit.Emulator.open(80,24,1000,"xterm-256color",false),false);
		try return new TerminalPane(session,requestFrame,palette,providedFonts,backend)
		catch (failure:Dynamic) { session.close(); throw failure; }
	}

	public function terminate(force:Bool):Void session.terminate(force);

	public function controlStatus():Null<String> return remoteBackend == null ? null : remoteBackend.controlStatus();

	public function status():String
		return session.status;

	/** Bounded renderer state for lifecycle and browser acceptance diagnostics. */
	public function diagnosticState():Dynamic return {
		width: resolvedWidth, height: resolvedHeight,
		cellWidth: cellWidth, rowHeight: rowHeight,
		cursorColumn: cursorColumn, cursorRow: cursorRow,
		loading: remoteBackend != null && !remoteBackend.isSynchronized(),
		lines: [for (index in 0...Std.int(Math.min(texts.length, 32))) StringTools.rtrim(texts[index])]
	};

	public function columns():Int
		return session.emulator.columns();

	public function rows():Int
		return session.emulator.rows();

	public function new(session:TerminalSession, requestFrame:Void->Void, palette:TerminalPalette, ?providedFonts:FontCollection,
		?remoteBackend:workspace.client.RpcTerminalBackend) {
		this.session = session;
		this.requestFrame = requestFrame;
		this.palette = palette;
		this.remoteBackend = remoteBackend;
		ownsFonts = providedFonts == null;
		foreground = palette.foreground;
		background = palette.background;
		cursorOutlineColor = foreground;
		fonts = providedFonts == null ? FontCollection.create() : providedFonts;
		if (ownsFonts) {
			var mono = Sys.getEnv("EXOSUIT_TERMINAL_FONT");
			if (mono == null || mono.length == 0)
				mono = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf";
			if (FileSystem.exists(mono)) fonts.add(mono, FontFamily.Monospace);
			fonts.addSystemFallbacks();
		}
		updateFontSize();
		if (remoteBackend != null) {
			controlLayout = TextLayout.create(fonts, "", 8192.0, new TextStyle(fontSize), new ParagraphStyle(TextWrap.None));
			controlLayout.setColor(foreground);
			controlActionLayout = TextLayout.create(fonts, "", 1024.0, new TextStyle(fontSize), new ParagraphStyle(TextWrap.None));
			controlActionLayout.setColor(palette.cursor);
			syncControlLayout();
		}
		refreshRows(true);
	}

	public function poll():Void {
		if (closed) return;
		if (foreground != palette.foreground || background != palette.background) {
			foreground = palette.foreground;
			background = palette.background;
			cursorOutlineColor = foreground;
			for (layout in layouts) layout.setColor(foreground);
			if (controlLayout != null) controlLayout.setColor(foreground);
			if (controlActionLayout != null) controlActionLayout.setColor(palette.cursor);
			refreshRows(true);
			requestFrame();
		}
		if (fontSize != palette.fontSize) {
			updateFontSize();
			resizeToViewport(resolvedWidth, resolvedHeight);
			requestFrame();
		}
		session.pollEvents();
		if (remoteBackend != null) syncControlLayout();
		refreshRows(false);
	}

	function syncControlLayout():Void {
		if (remoteBackend == null) return;
		var status = remoteBackend.controlStatus(), action = remoteBackend.controlAction();
		if (status != controlStatusText) {
			controlStatusText = status;
			controlLayout.setText(status);
			requestFrame();
		}
		if (action != controlActionText) {
			controlActionText = action;
			controlActionLayout.setText(action);
			requestFrame();
		}
	}

	/** Grid measurement and shaped rows must select the same fixed-pitch face. */
	function gridTextStyle():TextStyle return new TextStyle(fontSize, FontFamily.Monospace);

	function updateFontSize():Void {
		fontSize = palette.fontSize;
		var probe = TextLayout.create(fonts, "M", 64.0, gridTextStyle(), new ParagraphStyle(TextWrap.None));
		var metrics = probe.measure();
		cellWidth = Math.max(1.0, metrics.width);
		rowHeight = Math.max(1.0, Math.ceil(metrics.height + 2.0));
		probe.dispose();
		for (revision in revisions) if (revision >= fontRevision) fontRevision = revision + 1;
		for (layout in layouts) layout.dispose();
		viewportWidth = -1; viewportHeight = -1;
		layouts.resize(0); texts.resize(0); revisions.resize(0); backgrounds.resize(0);
	}

	function refreshRows(force:Bool, focusChanged:Bool = false):Void {
		var emulator = session.emulator;
		emulator.snapshot();
		var cursor = emulator.cursor();
		cursor.column = Std.int(Math.min(cursor.column, emulator.columns() - 1));
		cursor.row += emulator.scrollback(-1).current;
		var count = emulator.rows();
		while (layouts.length > count) {
			layouts.pop().dispose();
			texts.pop();
			revisions.pop();
			backgrounds.pop();
		}
		while (layouts.length < count) {
			var layout = TextLayout.create(fonts, "", 8192.0, gridTextStyle(), new ParagraphStyle(TextWrap.None));
			layout.setColor(foreground);
			layouts.push(layout);
			texts.push("");
			revisions.push(fontRevision);
			backgrounds.push([]);
			force = true;
		}
		for (row in 0...count) {
			var repaintCursor = focusChanged && (row == cursor.row || row == cursorRow);
			if (!force && !repaintCursor && !emulator.rowChanged(row)) continue;
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
				if (!focused && cursor.mode != 1 && row == cursor.row && column == cursor.column) {
					// libtsm paints its block cursor by swapping cell colors. Decode
					// each packed color in its emitted role before undoing that swap;
					// this also preserves default colors and inverse-video content.
					var ink = TerminalColors.decode(bg, background, palette, true);
					var paper = TerminalColors.decode(fg, foreground, palette, false);
					ranges.push(new TextColorRange(offset, offset + count, ink));
					fills.push({start: column, end: column + cell.width, color: paper});
					cursorOutlineColor = ink;
					cursorOutlineWidth = cell.width;
				} else {
					if ((fg & 3) != 0) ranges.push(new TextColorRange(offset, offset + count,
						TerminalColors.decode(fg, foreground, palette, false)));
					if ((bg & 3) != 0) fills.push({start: column, end: column + cell.width,
						color: TerminalColors.decode(bg, background, palette, true)});
				}
				offset += count;
			}
			var next = buffer.toString();
			if (force || repaintCursor || next != texts[row] || emulator.rowChanged(row)) {
				layouts[row].setText(next);
				layouts[row].setColorRanges(ranges);
				texts[row] = next;
				backgrounds[row] = fills;
				revisions[row]++;
			}
		}
		if (cursorRow != cursor.row || cursorColumn != cursor.column || cursorMode != cursor.mode) {
			if (cursorRow >= 0 && cursorRow < revisions.length) revisions[cursorRow]++;
			cursorRow = cursor.row;
			cursorColumn = cursor.column;
			cursorMode = cursor.mode;
			if (cursorRow >= 0 && cursorRow < revisions.length) revisions[cursorRow]++;
		}
	}

	function setFocused(value:Bool):Void {
		if (closed || focused == value) return;
		focused = value;
		focusGeneration++;
		session.emulator.focus(value);
		session.flushInput();
		refreshRows(false, true);
		requestFrame();
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
		if (remoteBackend != null) {
			var controlStyle = new LayoutStyle();
			controlStyle.width = LayoutAxis.grow();
			controlStyle.height = LayoutAxis.fixed(CONTROL_BAR_HEIGHT);
			var action = controlActionLayout;
			var status = controlLayout;
			var tint = Color.rgba(palette.cursor.red, palette.cursor.green, palette.cursor.blue, 0.12);
			var strip = new CanvasView("terminal-control-strip", function(canvas:Canvas, geometry) {
				canvas.fillRectIfPositive(new Rect(0.0, 0.0, geometry.width, geometry.height), tint);
				canvas.fillRectIfPositive(new Rect(0.0, 0.0, 3.0, geometry.height), palette.cursor);
				if (status != null) canvas.drawText(status, 10.0, 4.0);
				if (action != null && controlActionText.length > 0) {
					var metrics = action.measure();
					var width = metrics.width + 20.0;
					var x = Math.max(8.0, geometry.width - width - 8.0);
					canvas.fillRectIfPositive(new Rect(x, 2.0, width, geometry.height - 4.0), background);
					canvas.drawText(action, x + 10.0, 4.0);
				}
			}, controlStyle, "Terminal control", true);
			layers.push(new StackChild("control-strip", strip, 0.0, 0.0, 2,
				LayoutAxis.grow(), LayoutAxis.fixed(CONTROL_BAR_HEIGHT)));
		}
		var terminalTop = remoteBackend == null ? 4.0 : CONTROL_BAR_HEIGHT + 4.0;
		// Remote observers retain the sender's grid; build only rows intersecting our viewport.
		var visibleRows = resolvedHeight > 0 && (remoteBackend == null || remoteBackend.isSynchronized())
			? Std.int(Math.min(layouts.length, Math.max(0, Math.ceil((resolvedHeight - terminalTop) / rowHeight))))
			: 0;
		for (row in 0...visibleRows) {
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
				if (index == cursorRow && cursorMode != 1) {
					var x = 8.0 + cursorColumn * cellWidth;
					if (focused)
						canvas.fillRectIfPositive(new Rect(x, rowHeight - 2.0, cellWidth, 2.0), palette.cursor);
					else {
						var width = cursorOutlineWidth * cellWidth;
						canvas.fillRectIfPositive(new Rect(x, 0.0, width, 1.0), cursorOutlineColor);
						canvas.fillRectIfPositive(new Rect(x, rowHeight - 1.0, width, 1.0), cursorOutlineColor);
						canvas.fillRectIfPositive(new Rect(x, 1.0, 1.0, rowHeight - 2.0), cursorOutlineColor);
						canvas.fillRectIfPositive(new Rect(x + width - 1.0, 1.0, 1.0, rowHeight - 2.0), cursorOutlineColor);
					}
				}
			}, rowStyle, null, false, CachePolicy.Raster, key);
			layers.push(new StackChild('row-$index', view, 0.0, terminalTop + index * rowHeight,
				1, LayoutAxis.grow(), LayoutAxis.fixed(rowHeight)));
		}
		var node = new Stack("terminal-pane", layers, fill).build(context);
		// A terminal is an input stream, not an editable copy of its screen. Publish
		// an empty surrounding document so IME edits cannot target the last editor.
		var syncTextInput = function() {
			if (!focused || !context.textInput.isOwner(node.id)) return;
			var bounds = node.globalBounds();
			context.textInput.update(new TextInputWindow("", 0, 0), 0, 0, 0, -1, -1, 0, 0,
				new Rect(bounds.x + 8 + Math.max(0, cursorColumn) * cellWidth,
					bounds.y + terminalTop + Math.max(0, cursorRow) * rowHeight,
					cellWidth, rowHeight), [], []);
		};
		node.onResolved(function(_) {
			syncTextInput();
			var bounds = node.globalBounds();
			if (bounds.width != resolvedWidth || bounds.height != resolvedHeight) {
				resolvedWidth = bounds.width;
				resolvedHeight = bounds.height;
				requestFrame();
			}
		});
		node.focusable = true;
		node.on(UiEventKind.PointerDown, function(event) {
			context.requestFocus(node.id);
			if (closed) return;
			if (remoteBackend != null && event.localY >= 0 && event.localY < CONTROL_BAR_HEIGHT) {
				if (event.button == 0) {
					controlPointer = event.pointerId;
					event.capturePointer();
					event.preventDefault();
					event.stopPropagation();
				}
				return;
			}
			if ((event.modifiers & UiModifier.Shift) != 0 || session.emulator.mouseMode() == 0) {
				if (event.button != 0 || selectionPointer >= 0) return;
				var cell = pointerCell(event);
				selectionPointer = event.pointerId;
				selectionColumn = cell.column;
				selectionRow = cell.row;
				selectionMoved = false;
				session.emulator.selectionStart(cell.column, cell.row);
				hasSelection = true;
				refreshRows(false);
				requestFrame();
				event.capturePointer();
				event.preventDefault();
				event.stopPropagation();
				return;
			}
			var button = switch event.button {
				case 0: 0;
				case 1: 2;
				case 2: 1;
				default: -1;
			};
			if (button < 0 || mouseButton >= 0) return;
			if (reportMouse(event, button, 1)) {
				mouseButton = button;
				mousePointer = event.pointerId;
				event.capturePointer();
			}
		});
		node.on(UiEventKind.PointerMove, function(event) {
			if (controlPointer >= 0) return;
			if (selectionPointer >= 0) {
				if (event.pointerId != selectionPointer || closed) return;
				updateSelection(event);
				return;
			}
			if (mouseButton >= 0 && event.pointerId != mousePointer) return;
			if ((event.modifiers & UiModifier.Shift) != 0 && mouseButton < 0) return;
			if (!closed && session.emulator.mouseMode() != 0)
				reportMouse(event, mouseButton >= 0 ? mouseButton + 32 : 0, 4);
		});
		var releaseMouse = function(event:UiEvent) {
			if (controlPointer == event.pointerId) {
				if (event.kind != UiEventKind.PointerCancel && event.localY >= 0 && event.localY < CONTROL_BAR_HEIGHT)
					remoteBackend.activateControl();
				controlPointer = -1;
				event.releasePointer();
				event.preventDefault();
				event.stopPropagation();
				return;
			}
			if (selectionPointer == event.pointerId) {
				if (!closed && event.kind != UiEventKind.PointerCancel) updateSelection(event);
				selectionPointer = -1;
				if (!selectionMoved) clearSelection();
				event.releasePointer();
				event.preventDefault();
				event.stopPropagation();
				return;
			}
			if (mouseButton < 0 || event.pointerId != mousePointer) return;
			if (!closed) reportMouse(event, mouseButton, 2);
			mouseButton = -1;
			mousePointer = -1;
			event.releasePointer();
		};
		node.on(UiEventKind.PointerUp, releaseMouse);
		node.on(UiEventKind.PointerCancel, releaseMouse);
		node.on(UiEventKind.TextInput, function(event:UiEvent) {
			if (event.text != null && event.text.length > 0) {
				if (!canSendInput()) { event.preventDefault(); return; }
				prepareInput();
				session.write(Bytes.ofString(event.text));
				event.preventDefault();
			}
		});
		node.on(UiEventKind.TextEdit, function(event:UiEvent) {
			var edit:NativeKitTextEdit = cast event.data;
			// Composition previews stay with the platform IME. Only committed text
			// enters the PTY; sending previews would execute unfinished input.
			if (edit != null && edit.action == TextEditAction.Commit &&
				edit.text != null && edit.text.length > 0 && canSendInput()) {
				prepareInput();
				session.write(Bytes.ofString(edit.text));
			}
			event.preventDefault();
		});
		node.on(UiEventKind.KeyDown, function(event) {
			if (event.key == UiKey.C &&
				(event.modifiers & (UiModifier.Control | UiModifier.Shift)) ==
				(UiModifier.Control | UiModifier.Shift)) {
				var selected = session.emulator.selectionText();
				if (selected != null && selected.length > 0) context.clipboard.writeText(selected);
				event.preventDefault();
				return;
			}
			var paste = event.key == UiKey.V &&
				(event.modifiers & (UiModifier.Control | UiModifier.Shift)) ==
				(UiModifier.Control | UiModifier.Shift);
			if (paste) {
				if (!canSendInput()) { event.preventDefault(); return; }
				var generation = focusGeneration;
				context.clipboard.readText(function(text) {
					if (closed || !focused || generation != focusGeneration || session.status != "running" || text.length == 0) return;
					prepareInput();
					session.emulator.paste(Bytes.ofString(text));
					session.flushInput();
					session.pollEvents();
					requestFrame();
				});
				event.preventDefault();
			} else handleKey(event);
		});
		node.on(UiEventKind.KeyRepeat, handleKey);
		node.on(UiEventKind.Focus, function(_) {
			setFocused(true);
			context.textInput.activate(node.id);
			syncTextInput();
		});
		var blur = function(_:UiEvent):Void {
			setFocused(false);
			context.textInput.deactivate(node.id);
		};
		node.on(UiEventKind.Blur, blur);
		node.on(UiEventKind.FocusLost, blur);
		node.on(UiEventKind.Scroll, function(event:UiEvent) {
			if (event.deltaY == 0 || closed) return;
			if ((event.modifiers & UiModifier.Shift) == 0) {
				var button = event.deltaY < 0 ? 64 : 65;
				if (reportMouse(event, button, 1)) return;
			}
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

	function pointerCell(event:UiEvent):{column:Int, row:Int} {
		var column = Std.int(Math.floor((event.localX - 8.0) / cellWidth));
		var top = remoteBackend == null ? 4.0 : CONTROL_BAR_HEIGHT + 4.0;
		var row = Std.int(Math.floor((event.localY - top) / rowHeight));
		column = Std.int(Math.max(0, Math.min(session.emulator.columns() - 1, column)));
		row = Std.int(Math.max(0, Math.min(session.emulator.rows() - 1, row)));
		return {column: column, row: row};
	}

	function prepareInput():Void {
		clearSelection();
		if (session.emulator.scrollback(-1).current == 0) return;
		session.emulator.scrollback(0);
		refreshRows(true);
		requestFrame();
	}

	function clearSelection():Void {
		if (!hasSelection || closed) return;
		session.emulator.selectionClear();
		hasSelection = false;
		refreshRows(false);
		requestFrame();
	}

	function updateSelection(event:UiEvent):Void {
		var cell = pointerCell(event);
		if (cell.column != selectionColumn || cell.row != selectionRow) selectionMoved = true;
		session.emulator.selectionTarget(cell.column, cell.row);
		refreshRows(false);
		requestFrame();
		event.preventDefault();
		event.stopPropagation();
	}

	/** UIKit button/modifier values differ from the terminal wire protocol. */
	function reportMouse(event:UiEvent, button:Int, kind:Int):Bool {
		if (!canSendInput()) return false;
		var cell = pointerCell(event);
		var modifiers = 0;
		if ((event.modifiers & UiModifier.Shift) != 0) modifiers |= 4;
		if ((event.modifiers & UiModifier.Alt) != 0) modifiers |= 8;
		if ((event.modifiers & UiModifier.Control) != 0) modifiers |= 16;
		if (!session.emulator.mouse(cell.column, cell.row, button, kind, modifiers)) return false;
		session.flushInput();
		session.pollEvents();
		event.preventDefault();
		event.stopPropagation();
		requestFrame();
		return true;
	}

	function handleKey(event:UiEvent):Void {
		if (!canSendInput()) { event.preventDefault(); return; }
		if ((event.key == UiKey.V || event.key == UiKey.C) &&
			(event.modifiers & (UiModifier.Control | UiModifier.Shift)) ==
			(UiModifier.Control | UiModifier.Shift)) {
			event.preventDefault();
			return;
		}
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
		if (name != null) prepareInput();
		if (name != null && session.emulator.key(name, event.modifiers)) {
			session.flushInput();
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
			prepareInput();
			session.write(Bytes.ofString(bytes));
			event.preventDefault();
		}
	}

	function resizeToViewport(width:Float, height:Float):Void {
		var topInset = remoteBackend == null ? 8.0 : CONTROL_BAR_HEIGHT + 8.0;
		if (closed || width < 16.0 + cellWidth || height < topInset + rowHeight) return;
		if (width == viewportWidth && height == viewportHeight) return;
		viewportWidth = width;
		viewportHeight = height;
		var columns = Std.int(Math.max(1.0, Math.min(512.0, Math.floor((width - 16.0) / cellWidth))));
		var rows = Std.int(Math.max(1.0, Math.min(256.0, Math.floor((height - topInset) / rowHeight))));
		// Desired geometry also seeds OPEN and is retained while observing another controller.
		if (remoteBackend == null && columns == session.emulator.columns() && rows == session.emulator.rows()) return;
		session.resize(columns, rows);
		if (remoteBackend == null) {
			// Re-render all rows now; waiting for PTY output leaves stale/missing rows while dragging.
			refreshRows(true);
			requestFrame();
		}
	}

	function canSendInput():Bool return remoteBackend == null || !remoteBackend.isAttached() || remoteBackend.canControl();

	public function close():Void {
		if (closed) return;
		closed = true;
		for (layout in layouts) layout.dispose();
		layouts.resize(0);
		if (controlLayout != null) controlLayout.dispose();
		if (controlActionLayout != null) controlActionLayout.dispose();
		if (ownsFonts) fonts.dispose();
		session.close();
	}
}
