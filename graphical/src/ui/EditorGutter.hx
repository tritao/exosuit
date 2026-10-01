package ui;

import Color;
import Insets;
import LayoutAxis;
import LayoutDirection;
import LayoutStyle;
import nativekit.ui.core.BuildContext;
import nativekit.ui.core.RenderNode;
import nativekit.ui.core.View;
import nativekit.ui.core.TextStyleOverride;
import nativekit.ui.widgets.KeyedView;
import nativekit.ui.widgets.layout.Column;
import nativekit.ui.widgets.text.Text;
import editor.TextBuffer;

/**
 * Line-number gutter for the EditorKit-backed editor pane.
 *
 * This is a plain rebuilt column of line-number labels, not a virtualized or
 * independently-scrolled rail: `EditorPane` places it next to `TextArea` in
 * one shared `ScrollView`, so both scroll together by construction rather
 * than through an explicit scroll-position handshake. UIKit does not expose
 * per-widget scroll offsets to synchronize against directly; this sidesteps
 * that gap instead of working around it.
 */
class EditorGutter implements View {
	final key:String;
	final buffer:TextBuffer;
	final foreground:Color;
	final background:Null<Color>;

	public function new(key:String, buffer:TextBuffer, foreground:Color, ?background:Color) {
		this.key = key;
		this.buffer = buffer;
		this.foreground = foreground;
		this.background = background;
	}

	public function build(context:BuildContext):RenderNode {
		var count = buffer.lineCount();
		var digits = Std.string(count == 0 ? 1 : count).length;
		var rows:Array<KeyedView> = [];
		for (index in 0...count) {
			var label = padLeft(Std.string(index + 1), digits);
			var rowStyle = new LayoutStyle();
			// The enclosing Column below sizes itself with LayoutAxis.fit(), i.e.
			// to its children's own intrinsic width. A `stretch()` (100% of the
			// parent) row width is circular against that and resolves to zero,
			// which was collapsing every line-number label to an invisible
			// zero-width box. `fit()` lets each label size to its own text.
			rowStyle.width = LayoutAxis.fit();
			rowStyle.direction = LayoutDirection.LeftToRight;
			rows.push(new KeyedView("line:" + index, new Text(label, rowStyle, foreground,
				TextStyleOverride.text(13.0))));
		}
		var columnStyle = new LayoutStyle();
		columnStyle.width = LayoutAxis.fit();
		columnStyle.padding = new Insets(6.0, 4.0, 6.0, 0.0);
		if (background != null) columnStyle.background = background;
		return new Column(key, rows, columnStyle).build(context);
	}

	static function padLeft(value:String, width:Int):String {
		var result = value;
		while (result.length < width) result = " " + result;
		return result;
	}
}
