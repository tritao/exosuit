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
private typedef TerminalForeground = {start:Int, end:Int, packed:Int, background:Bool};
private typedef TerminalRow = {
	layout:TextLayout, text:String, fills:Array<TerminalBackground>, grid:Bool, selected:Bool,
	id:haxe.Int64, hash:haxe.Int64, reusable:Bool, serial:Int, paintRevision:Int, paintKey:String
};

/** Retained terminal rows; each row reuses a display list and shaped text. */
class TerminalPane implements AgentTerminalPanel {
	static inline final CONTROL_BAR_HEIGHT:Float = 26.0;
	public final session:TerminalSession;
	final requestFrame:Void->Void;
	final fonts:FontCollection;
	final renderedRows:Array<TerminalRow> = [];
	final revisions:Array<Int> = [];
	final palette:TerminalPalette;
	final ownsFonts:Bool;
	final remoteBackend:Null<workspace.client.RpcTerminalBackend>;
	var controlStatusText:String = "";
	var controlActionText:String = "";
	var foreground:Color;
	var background:Color;
	var cellWidth:Float;
	var rowHeight:Float;
	var fontSize:Float;
	var fontRevision:Int = 0;
	var rowSerial:Int = 0;
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
	final selectionGesture = new haxeon.ui.core.SelectionGesture();
	final selectionDrag = new haxeon.ui.widgets.text.SelectionDragController();
	var selectionScroll:Float = 0;
	var selectionColor:Color = Color.rgba(0.2, 0.43, 0.82, 0.55);
	var selectionPaintChanged:Bool = false;
	var hasSelection:Bool = false;
	var mouseButton:Int = -1;
	var mousePointer:Int = -1;
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

	public function configureAgent(provider:String):Void {
		if (remoteBackend == null) throw "Agent CLIs require a workspace-owned terminal";
		remoteBackend.configureAgent(provider);
	}
	public function controlStatus():Null<String> return remoteBackend == null ? null : remoteBackend.controlStatus();

	public function status():String
		return session.status;

	public function workspaceName():Null<String> return remoteBackend == null ? null : remoteBackend.name;

	/** Bounded renderer state for lifecycle and browser acceptance diagnostics. */
	public function diagnosticState():Dynamic return {
		width: resolvedWidth, height: resolvedHeight,
		cellWidth: cellWidth, rowHeight: rowHeight,
		cursorColumn: cursorColumn, cursorRow: cursorRow,
		loading: remoteBackend != null && !remoteBackend.isSynchronized(),
		win32Input: !closed && session.emulator.win32InputMode(),
		lines: [for (index in 0...Std.int(Math.min(renderedRows.length, 32))) StringTools.rtrim(renderedRows[index].text)]
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
		syncDefaultColors();
		fonts = providedFonts == null ? FontCollection.create() : providedFonts;
		if (ownsFonts) {
			// The first monospace face present on this host; system fallbacks are proportional.
			for (mono in [Sys.getEnv("EXOSUIT_TERMINAL_FONT"), "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
					"/System/Library/Fonts/Menlo.ttc", "C:/Windows/Fonts/consola.ttf"])
				if (mono != null && mono.length > 0 && FileSystem.exists(mono)) {
					fonts.add(mono, FontFamily.Monospace);
					break;
				}
			fonts.addSystemFallbacks();
		}
		updateFontSize();
		if (remoteBackend != null) syncControlLayout();
		refreshRows(true);
	}

	function syncDefaultColors():Void {
		var fg = rgbColor(foreground), bg = rgbColor(background);
		session.emulator.setDefaultColors(fg, bg);
		if (remoteBackend != null) remoteBackend.setDefaultColors(fg, bg);
	}

	static function rgbColor(color:Color):Int
		return (Math.round(color.red * 255) << 16) | (Math.round(color.green * 255) << 8) | Math.round(color.blue * 255);

	public function poll():Void {
		if (closed) return;
		if (foreground != palette.foreground || background != palette.background) {
			foreground = palette.foreground;
			background = palette.background;
			cursorOutlineColor = foreground;
			syncDefaultColors();
			for (row in renderedRows) row.layout.setColor(foreground);
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
		// Shell echo and cursor motion arrive asynchronously, often after the
		// frame requested by the key itself. Schedule their presentation too.
		if (refreshRows(false)) requestFrame();
	}

	/** Keep the normal writable terminal quiet; show states that need attention. */
	function showControlNotice():Bool
		return remoteBackend != null && remoteBackend.needsControlNotice();

	function syncControlLayout():Void {
		if (remoteBackend == null) return;
		var status = remoteBackend.controlStatus(), action = remoteBackend.controlAction();
		if (status != controlStatusText) {
			viewportHeight = -1; // The notice can appear or disappear without a viewport resize.
			controlStatusText = status;
			requestFrame();
		}
		if (action != controlActionText) {
			controlActionText = action;
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
		for (row in renderedRows) row.layout.dispose();
		viewportWidth = -1; viewportHeight = -1;
		renderedRows.resize(0); revisions.resize(0);
	}

	/** Move unchanged rows before recycling storage for newly visible content. */
	function relocateRows(nextCursorRow:Int, nextCursorMode:Int, focusChanged:Bool):Array<Int> {
		var emulator = session.emulator;
		var count = renderedRows.length;
		// Match all destinations before recycling layouts, so a new line cannot
		// overwrite a layout that a later viewport row still needs.
		var previous = renderedRows.copy();
		var byId:Map<String, Int> = new Map();
		for (index in 0...count) {
			var entry = previous[index];
			if (entry.reusable && entry.id != 0) byId.set(haxe.Int64.toStr(entry.id), index);
		}
		var sources:Array<Int> = [];
		var ids:Array<haxe.Int64> = [];
		var hashes:Array<haxe.Int64> = [];
		var used = [for (_ in 0...count) false];
		for (row in 0...count) {
			var id = emulator.rowId(row), hash = emulator.rowHash(row);
			ids.push(id); hashes.push(hash);
			var source = -1;
			var repaintCursor = focusChanged && (row == nextCursorRow || row == cursorRow);
			if (!repaintCursor && previous[row].id == id && previous[row].hash == hash
				&& !emulator.rowChanged(row)) source = row;
			else if (!repaintCursor && (nextCursorMode == 1 || row != nextCursorRow)) {
				var candidate = byId.get(haxe.Int64.toStr(id));
				if (candidate != null && !used[candidate] && previous[candidate].hash == hash) source = candidate;
			}
			if (source >= 0) used[source] = true;
			sources.push(source);
		}
		var recycle = 0;
		for (row in 0...count) {
			var source = sources[row];
			if (source < 0) {
				while (used[recycle]) recycle++;
				source = recycle++;
			}
			var entry = previous[source];
			renderedRows[row] = entry;
			entry.id = ids[row]; entry.hash = hashes[row];
			// An unfocused cursor repairs libtsm's swapped cell colors. Keep
			// cursor-bearing rows out of cross-position reuse in either focus mode.
			entry.reusable = nextCursorMode == 1 || row != nextCursorRow;
			if (sources[row] >= 0) {
				if (source != row) revisions[row]++;
			}
		}
		return sources;
	}

	function refreshRows(force:Bool, focusChanged:Bool = false):Bool {
		var emulator = session.emulator;
		var changed = emulator.snapshot();
		var cursor = emulator.cursor();
		cursor.column = Std.int(Math.min(cursor.column, emulator.columns() - 1));
		cursor.row += emulator.scrollback(-1).current;
		var count = emulator.rows();
		if (!force && !focusChanged && !selectionPaintChanged && changed == 0 && count == renderedRows.length
			&& cursorRow == cursor.row && cursorColumn == cursor.column && cursorMode == cursor.mode) return false;
		while (renderedRows.length > count) {
			renderedRows.pop().layout.dispose();
			revisions.pop();
		}
		while (renderedRows.length < count) {
			var layout = TextLayout.create(fonts, "", 8192.0, gridTextStyle(), new ParagraphStyle(TextWrap.None));
			layout.setColor(foreground);
			renderedRows.push({layout: layout, text: "", fills: [], grid: false, selected: false, id: 0, hash: 0, reusable: false, serial: ++rowSerial, paintRevision: 0, paintKey: ""});
			revisions.push(fontRevision);
			force = true;
		}
		var moved = false;
		if (!force) for (row in 0...count) {
			if (renderedRows[row].id != emulator.rowId(row)) { moved = true; break; }
		}
		var sources = moved ? relocateRows(cursor.row, cursor.mode, focusChanged) : null;
		for (row in 0...count) {
			var repaintCursor = focusChanged && (row == cursor.row || row == cursorRow);
			var repaintSelection = selectionPaintChanged && renderedRows[row].selected;
			if (sources != null) {
				if (sources[row] >= 0 && !repaintSelection) continue;
			} else if (!force && !repaintCursor && !repaintSelection && !emulator.rowChanged(row)) continue;
			var entry = renderedRows[row];
			entry.selected = false;
			entry.id = emulator.rowId(row); entry.hash = emulator.rowHash(row);
			entry.reusable = cursor.mode == 1 || row != cursor.row;
			var cells = emulator.rowCells(row);
			var buffer = new StringBuf();
			var grid:Array<Float> = [];
			var gridRequired = false;
			var inkRuns:Array<TerminalForeground> = [];
			var fills:Array<TerminalBackground> = [];
			var offset = 0;
			for (column in 0...cells.length) {
				var cell:Cell = cells[column];
				if (cell.width == 0) continue;
				var content = cell.text.length == 0 ? " " : cell.text;
				buffer.add(content);
				var count = codepoints(content);
				if (!gridRequired && (count != 1 || content.charCodeAt(0) >= 127)) {
					gridRequired = true;
					for (previous in 0...offset) grid.push(previous * cellWidth);
				}
				if (gridRequired) for (_ in 0...count) grid.push(column * cellWidth);
				var fg = haxe.Int64.toInt(cell.style);
				var bg = haxe.Int64.toInt(cell.style >>> 32);
				if (!focused && cursor.mode != 1 && row == cursor.row && column == cursor.column) {
					// libtsm paints its block cursor by swapping cell colors. Decode
					// each packed color in its emitted role before undoing that swap;
					// this also preserves default colors and inverse-video content.
					var ink = TerminalColors.decode(bg, background, palette, true);
					var paper = TerminalColors.decode(fg, foreground, palette, false);
					appendForeground(inkRuns, offset, offset + count, bg, true);
					appendBackground(fills, column, column + cell.width, paper);
					cursorOutlineColor = ink;
					cursorOutlineWidth = cell.width;
				} else {
					if ((fg & 3) != 0) appendForeground(inkRuns, offset, offset + count, fg, false);
					if ((bg & 3) != 0) appendBackground(fills, column, column + cell.width,
						TerminalColors.decode(bg, background, palette, true));
				}
				if ((fg & terminalkit.Emulator.SELECTED) != 0) {
					entry.selected = true;
					appendBackground(fills, column, column + cell.width, selectionColor);
				}
				offset += count;
			}
			var next = buffer.toString();
			if (next != entry.text) entry.layout.setText(next);
			if (gridRequired) {
				grid.push(cells.length * cellWidth);
				entry.layout.setGridPositions(grid);
			} else if (entry.grid) entry.layout.setGridPositions([]);
			entry.grid = gridRequired;
			entry.layout.setColorRanges([for (run in inkRuns) new TextColorRange(run.start, run.end,
				TerminalColors.decode(run.packed, run.background ? background : foreground, palette, run.background))]);
			entry.text = next;
			entry.fills = fills;
			entry.paintRevision++;
			entry.paintKey = 'terminal-row-${entry.serial}-${entry.paintRevision}';
			revisions[row]++;
		}
		if (cursorRow != cursor.row || cursorColumn != cursor.column || cursorMode != cursor.mode) {
			if (cursorRow >= 0 && cursorRow < revisions.length) revisions[cursorRow]++;
			cursorRow = cursor.row;
			cursorColumn = cursor.column;
			cursorMode = cursor.mode;
			if (cursorRow >= 0 && cursorRow < revisions.length) revisions[cursorRow]++;
		}
		terminalsession.TerminalLatencyTrace.mark("terminal.rows.ready");
		selectionPaintChanged = false;
		return true;
	}

	/** Keep codepoint offsets and cursor color roles while decoding only once per run. */
	static function appendForeground(runs:Array<TerminalForeground>, start:Int, end:Int, packed:Int, background:Bool):Void {
		var previous = runs.length == 0 ? null : runs[runs.length - 1];
		if (previous != null && previous.end == start && previous.packed == packed && previous.background == background)
			previous.end = end;
		else runs.push({start: start, end: end, packed: packed, background: background});
	}

	/** One fill per color run avoids antialiased seams at fractional cell edges. */
	static function appendBackground(fills:Array<TerminalBackground>, start:Int, end:Int, color:Color):Void {
		var previous = fills.length == 0 ? null : fills[fills.length - 1];
		if (previous != null && previous.end == start && previous.color.red == color.red
			&& previous.color.green == color.green && previous.color.blue == color.blue && previous.color.alpha == color.alpha)
			previous.end = end;
		else fills.push({start: start, end: end, color: color});
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

	/** Typed text follows the shell's input mode; ConPTY asks for Win32 key events. */
	function sendText(text:String):Void {
		session.emulator.text(Bytes.ofString(text));
		session.flushInput();
	}

	static function codepoints(value:String):Int {
		var bytes = Bytes.ofString(value);
		var count = 0;
		for (i in 0...bytes.length) if ((bytes.get(i) & 0xc0) != 0x80) count++;
		return count;
	}

	public function build(context:BuildContext):RenderNode {
		var highlight = focused ? context.theme.textSelection : context.theme.textSelectionInactive;
		if (selectionColor != highlight) { selectionColor = highlight; selectionPaintChanged = true; refreshRows(false); }
		// Resize before creating row painters; painting must not invalidate this frame.
		resizeToViewport(resolvedWidth, resolvedHeight);
		var fill = new LayoutStyle();
		fill.width = LayoutAxis.grow();
		fill.height = LayoutAxis.grow();
		var backdrop = new CanvasView("terminal-backdrop", function(canvas:Canvas, geometry) {
			canvas.fillRectIfPositive(new Rect(0.0, 0.0, geometry.width, geometry.height), background);
		}, fill, "Terminal", true);
		var layers:Array<StackChild> = [new StackChild("background", backdrop, 0.0, 0.0, 0,
			LayoutAxis.grow(), LayoutAxis.grow())];
		var terminalNode:Null<RenderNode> = null;
		if (showControlNotice()) {
			var controlStyle = new LayoutStyle();
			controlStyle.width = LayoutAxis.grow();
			controlStyle.height = LayoutAxis.fixed(CONTROL_BAR_HEIGHT);
			controlStyle.direction = haxeon.ui.LayoutDirection.LeftToRight;
			controlStyle.childAlignY = haxeon.ui.LayoutAlignmentY.Center;
			controlStyle.childGap = 8;
			controlStyle.padding = new haxeon.ui.Insets(8, 1, 8, 1);
			controlStyle.background = Color.rgba(palette.cursor.red, palette.cursor.green, palette.cursor.blue, 0.12);
			var status = new haxeon.ui.widgets.text.MiddleEllipsisText("terminal-control-status",controlStatusText,false,
				haxeon.ui.core.TextStyleOverride.text(ExosuitPalette.WORKBENCH_TEXT_SIZE));
			var hint = new haxeon.ui.widgets.overlays.Tooltip("terminal-control-status-tip",status,
				new haxeon.ui.widgets.text.Text(controlStatusText));
			hint.fillAnchor = true;
			hint.placement = haxeon.ui.widgets.overlays.TooltipPlacement.Below;
			hint.showWhen = function() return status.truncated;
			var controls:Array<haxeon.ui.widgets.KeyedView> = [new haxeon.ui.widgets.KeyedView("status",hint)];
			if (controlActionText.length > 0) {
				var buttonStyle = new LayoutStyle();
				buttonStyle.height = LayoutAxis.fixed(CONTROL_BAR_HEIGHT - 2);
				buttonStyle.padding = new haxeon.ui.Insets(8, 0, 8, 0);
				var action = new haxeon.ui.widgets.controls.Button(controlActionText == "Restart Terminal" ? "Restart" : controlActionText,buttonStyle,function() {
					remoteBackend.activateControl();syncControlLayout();requestFrame();
					if (terminalNode != null) context.requestFocusAfterLayout(terminalNode.id);
				},"terminal-control-action");
				action.variant = haxeon.ui.widgets.controls.ButtonVariant.Secondary;
				action.accessibilityLabel = controlActionText;
				controls.push(new haxeon.ui.widgets.KeyedView("action",action));
			}
			var strip = new haxeon.ui.widgets.layout.Row("terminal-control-strip",controls,controlStyle);
			layers.push(new StackChild("control-strip", strip, 0.0, 0.0, 2,
				LayoutAxis.grow(), LayoutAxis.fixed(CONTROL_BAR_HEIGHT)));
		}
		var terminalTop = showControlNotice() ? CONTROL_BAR_HEIGHT + 4.0 : 4.0;
		// Remote observers retain the sender's grid; build only rows intersecting our viewport.
		var visibleRows = resolvedHeight > 0 && (remoteBackend == null || remoteBackend.isSynchronized())
			? Std.int(Math.min(renderedRows.length, Math.max(0, Math.ceil((resolvedHeight - terminalTop) / rowHeight))))
			: 0;
		// Row display lists and glyphs are already retained. An extra raster target
		// per row adds offscreen rendering and compositing work during updates.
		for (row in 0...visibleRows) {
			var index = row;
			var rowStyle = new LayoutStyle();
			rowStyle.width = LayoutAxis.grow();
			rowStyle.height = LayoutAxis.fixed(rowHeight);
			var entry = renderedRows[index];
			var serial = entry.serial;
			// Follow row storage through scrolling so its encoded paint survives moves.
			// Storage IDs keep UI/style identities bounded as new lines arrive.
			var key = entry.paintKey;
			if (index == cursorRow && cursorMode != 1) key += '-cursor-$cursorColumn-$cursorMode-$focusGeneration';
			var view = new CanvasView('terminal-row-$serial', function(canvas:Canvas, geometry) {
				canvas.fillRectIfPositive(new Rect(0.0, 0.0, geometry.width, geometry.height), background);
				for (fill in renderedRows[index].fills) canvas.fillRectIfPositive(new Rect(8.0 + fill.start * cellWidth,
					0.0, (fill.end - fill.start) * cellWidth, rowHeight), fill.color);
				canvas.drawText(renderedRows[index].layout, 8.0, 0.0);
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
			}, rowStyle, null, false, CachePolicy.None, key);
			layers.push(new StackChild('row-$serial', view, 0.0, terminalTop + index * rowHeight,
				1, LayoutAxis.grow(), LayoutAxis.fixed(rowHeight)));
		}
		var node = new Stack("terminal-pane", layers, fill).build(context);
		terminalNode = node;
		node.commandShortcutFilter = function(id) return TerminalShortcutPolicy.allows(id);
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
			selectionDrag.layoutResolved();
			syncTextInput();
			var bounds = node.globalBounds();
			if (bounds.width != resolvedWidth || bounds.height != resolvedHeight) {
				resolvedWidth = bounds.width;
				resolvedHeight = bounds.height;
				requestFrame();
			}
		});
		node.focusable = true;
		selectionDrag.configureAdapter(context.animations, function() return !closed && selectionPointer >= 0,
			function() return node.resolved, function(x, y) {
				var point = node.globalToLocal(new haxeon.ui.Point(x, y));
				updateSelectionAt(point.x, point.y);
			}, function(delta) {
				selectionScroll += delta / rowHeight;
				var lines = Std.int(selectionScroll);
				if (lines == 0) return true;
				selectionScroll -= lines;
				var before = session.emulator.scrollback(-1).current;
				var after = session.emulator.scrollback(Std.int(Math.max(0, before - lines))).current;
				if (before == after) return false;
				selectionMoved = true; refreshRows(false); requestFrame(); return true;
			});
		node.on(UiEventKind.PointerDown, function(event) {
			if (closed) return;
			if (showControlNotice() && event.localY >= 0 && event.localY < CONTROL_BAR_HEIGHT) return;
			context.requestFocus(node.id);
			if ((event.modifiers & UiModifier.Shift) != 0 || session.emulator.mouseMode() == 0) {
				if (event.button != 0 || selectionPointer >= 0) return;
				var cell = pointerCell(event);
				selectionPointer = event.pointerId;
				selectionColumn = cell.column;
				selectionRow = cell.row;
				selectionScroll = 0;
				// With mouse tracking Shift means "select locally"; outside a TUI it extends the anchor.
				var extend = (event.modifiers & UiModifier.Shift) != 0 && session.emulator.mouseMode() == 0 && hasSelection;
				if (extend) selectionGesture.cancel();
				// Row identity plus shared pixel slop tolerates clicks straddling a cell edge.
				var clicks = extend ? 1 : selectionGesture.register(haxe.Int64.toStr(session.emulator.rowId(cell.row)),
					context.gestures.timeSeconds(), event.x, event.y);
				selectionGesture.granularity = clicks;
				selectionMoved = clicks > 1 || extend;
				if (extend) session.emulator.selectionExtend(cell.column, cell.row);
				else if (clicks == 2) session.emulator.selectionWord(cell.column, cell.row);
				else if (clicks == 3) session.emulator.selectionLine(cell.column, cell.row);
				else session.emulator.selectionStart(cell.column, cell.row);
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
			if (button == 0) {
				selectionGesture.cancel();
				clearSelection();
			}
			if (reportMouse(event, button, 1)) {
				mouseButton = button;
				mousePointer = event.pointerId;
				event.capturePointer();
			}
		});
		node.on(UiEventKind.PointerMove, function(event) {
			if (selectionPointer >= 0) {
				if (event.pointerId != selectionPointer || closed) return;
				selectionGesture.cancelIfMoved(event.x, event.y);
				updateSelection(event);
				selectionDrag.update(event.x, event.y);
				return;
			}
			if (mouseButton >= 0 && event.pointerId != mousePointer) return;
			if ((event.modifiers & UiModifier.Shift) != 0 && mouseButton < 0) return;
			if (!closed && session.emulator.mouseMode() != 0)
				reportMouse(event, mouseButton >= 0 ? mouseButton + 32 : 0, 4);
		});
		var releaseMouse = function(event:UiEvent) {
			if (selectionPointer == event.pointerId) {
				if (!closed && event.kind != UiEventKind.PointerCancel) updateSelection(event);
				selectionDrag.stop();
				if (event.kind == UiEventKind.PointerCancel) selectionGesture.cancel();
				else selectionGesture.complete(event.x, event.y);
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
			if (event.target != node.id) return;
			if (event.text != null && event.text.length > 0) {
				if (!canSendInput()) { event.preventDefault(); return; }
				prepareInput();
				sendText(event.text);
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
				sendText(edit.text);
			}
			event.preventDefault();
		});
		node.on(UiEventKind.KeyDown, function(event) {
			if (event.target != node.id) return;
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
					if (!focused || generation != focusGeneration || session.status != "running" || text.length == 0 || !canSendInput()) return;
					prepareInput();
					session.emulator.paste(Bytes.ofString(text));
					session.flushInput();
					session.pollEvents();
					requestFrame();
				});
				event.preventDefault();
			} else handleKey(event);
		});
		node.on(UiEventKind.KeyRepeat, function(event) { if (event.target == node.id) handleKey(event); });
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
			refreshRows(false);
			requestFrame();
			event.preventDefault();
		});
		if (!focusRequested) focusRequested = context.requestFocus(node.id);
		return node;
	}

	function pointerCell(event:UiEvent):{column:Int, row:Int} return cellAt(event.localX, event.localY);

	function cellAt(x:Float, y:Float):{column:Int, row:Int} {
		var column = Std.int(Math.floor((x - 8.0) / cellWidth));
		var top = showControlNotice() ? CONTROL_BAR_HEIGHT + 4.0 : 4.0;
		var row = Std.int(Math.floor((y - top) / rowHeight));
		column = Std.int(Math.max(0, Math.min(session.emulator.columns() - 1, column)));
		row = Std.int(Math.max(0, Math.min(session.emulator.rows() - 1, row)));
		return {column: column, row: row};
	}

	function prepareInput():Void {
		selectionGesture.cancel();
		clearSelection();
		if (session.emulator.scrollback(-1).current == 0) return;
		session.emulator.scrollback(0);
		refreshRows(false);
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
		updateSelectionAt(event.localX, event.localY);
		event.preventDefault();
		event.stopPropagation();
	}

	function updateSelectionAt(x:Float, y:Float):Void {
		var cell = cellAt(x, y);
		if (cell.column != selectionColumn || cell.row != selectionRow) selectionMoved = true;
		session.emulator.selectionTarget(cell.column, cell.row);
		refreshRows(false);
		requestFrame();
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
		var topInset = showControlNotice() ? CONTROL_BAR_HEIGHT + 8.0 : 8.0;
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
			// Consume the local backend's ordered geometry event before rebuilding row painters.
			// A geometry-only change must not wait for the background output poll.
			session.pollEvents();
			// Re-render all rows now; waiting for PTY output leaves stale/missing rows while dragging.
			refreshRows(true);
			requestFrame();
		}
	}

	/** Input before a remote terminal attaches is queued; a failed one (detached too) takes none. */
	function canSendInput():Bool
		return !closed && (remoteBackend == null || remoteBackend.isAvailable() && (!remoteBackend.isAttached() || remoteBackend.canControl()));

	public function close():Void {
		if (closed) return;
		selectionDrag.dispose();
		closed = true;
		for (row in renderedRows) row.layout.dispose();
		renderedRows.resize(0);
		if (ownsFonts) fonts.dispose();
		session.close();
	}
}
