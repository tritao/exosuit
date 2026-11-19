package ui.shell.phone;

import haxeon.ui.Color;
import haxeon.ui.Insets;
import haxeon.ui.LayoutAlignmentX;
import haxeon.ui.LayoutAlignmentY;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutDistribution;
import haxeon.ui.LayoutStyle;
import haxeon.ui.TextWrap;
import haxeon.ui.core.TextStyleOverride;
import haxeon.ui.core.View;
import haxeon.ui.gestures.LongPressRecognizer;
import haxeon.ui.gestures.TapRecognizer;
import haxeon.ui.icons.IconName;
import haxeon.ui.widgets.GestureDetector;
import haxeon.ui.widgets.Icon;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.layout.Column;
import haxeon.ui.widgets.layout.Row;
import haxeon.ui.widgets.text.Text;

/** The phone design tokens (docs/phone-ui/CONTRACTS.md) and the small view builders every phone screen shares. */
class PhoneUi {
	public static final GROUND = Color.fromBytes(0xf4, 0xf5, 0xf7);
	public static final SURFACE = Color.fromBytes(0xff, 0xff, 0xff);
	public static final TEXT = Color.fromBytes(0x16, 0x18, 0x1d);
	public static final SECONDARY = Color.fromBytes(0x55, 0x5b, 0x66);
	public static final MUTED = Color.fromBytes(0x8a, 0x90, 0x9b);
	public static final SECTION = Color.fromBytes(0x3d, 0x42, 0x4b);
	public static final ACCENT = Color.fromBytes(0x2f, 0x55, 0xc7);
	public static final ACCENT_TINT = Color.fromBytes(0xe8, 0xed, 0xfb);
	public static final ACCENT_DARK = Color.fromBytes(0x1f, 0x3f, 0x9e);
	public static final ATTENTION = Color.fromBytes(0xd9, 0x77, 0x06);
	public static final ATTENTION_TEXT = Color.fromBytes(0x8a, 0x4b, 0x00);
	public static final ATTENTION_TINT = Color.fromBytes(0xff, 0xf1, 0xdc);
	public static final IDLE = Color.fromBytes(0x9a, 0xa0, 0xaa);
	public static final CHIP = Color.fromBytes(0xec, 0xee, 0xf2);
	public static final RULE = Color.fromBytes(0xe2, 0xe4, 0xe9);
	public static final RULE_SOFT = Color.fromBytes(0xec, 0xee, 0xf2);
	public static final KEY_BORDER = Color.fromBytes(0xd5, 0xd8, 0xde);
	public static final ONLINE = Color.fromBytes(0x1a, 0x7f, 0x4b);
	public static final ONLINE_TEXT = Color.fromBytes(0x1a, 0x6b, 0x41);
	public static final DANGER = Color.fromBytes(0xa1, 0x2a, 0x2a);
	public static final WHITE = Color.fromBytes(0xff, 0xff, 0xff);

	public static function kv(key:String, view:View):KeyedView return new KeyedView(key, view);

	public static function radius(style:LayoutStyle, value:Float):LayoutStyle {
		style.radiusTopLeft = style.radiusTopRight = style.radiusBottomLeft = style.radiusBottomRight = value;
		return style;
	}

	/** Single-line text; `grow` lets it take the rest of its row and clip. */
	public static function text(value:String, size:Float, color:Color, grow:Bool = false, letterSpacing:Float = 0.0):Text {
		var style = new LayoutStyle();
		if (grow) {
			style.width = LayoutAxis.grow();
			style.clipHorizontal = true;
		}
		return new Text(value, style, color, new TextStyleOverride(null, size, letterSpacing == 0.0 ? null : letterSpacing, TextWrap.None, null, null, null, color));
	}

	public static function column(key:String, children:Array<KeyedView>, ?configure:LayoutStyle->Void):Column {
		var style = new LayoutStyle();
		if (configure != null) configure(style);
		return new Column(key, children, style);
	}

	public static function row(key:String, children:Array<KeyedView>, ?configure:LayoutStyle->Void):Row {
		var style = new LayoutStyle();
		style.childAlignY = LayoutAlignmentY.Center;
		if (configure != null) configure(style);
		return new Row(key, children, style);
	}

	/** A one-pixel divider. */
	public static function rule(key:String, ?color:Color):View
		return column(key, [], function(s) {
			s.width = LayoutAxis.stretch();
			s.height = LayoutAxis.fixed(1);
			s.background = color == null ? RULE : color;
		});

	public static function dot(key:String, color:Color):View
		return column(key, [], function(s) {
			s.width = LayoutAxis.fixed(8);
			s.height = LayoutAxis.fixed(8);
			s.background = color;
			radius(s, 4);
		});

	public static function filler(key:String, height:Float):View
		return column(key, [], function(s) {
			s.width = LayoutAxis.stretch();
			s.height = LayoutAxis.fixed(height);
		});

	/** A square or round coloured box with one centred child. */
	public static function tile(key:String, size:Float, round:Float, fill:Color, child:View):View
		return column(key, [kv("c", child)], function(s) {
			s.width = LayoutAxis.fixed(size);
			s.height = LayoutAxis.fixed(size);
			s.background = fill;
			radius(s, round);
			s.childAlignX = LayoutAlignmentX.Center;
			s.childDistribution = LayoutDistribution.Center;
		});

	/** A small rounded label (state badge). */
	public static function badge(key:String, label:String, fill:Color, ink:Color):View
		return row(key, [kv("t", text(label, 12, ink))], function(s) {
			s.padding = new Insets(8, 4, 8, 4);
			s.background = fill;
			radius(s, 10);
		});

	/** A non-interactive pill in the filter bar ("Sections: group"). */
	public static function pill(key:String, label:String, fill:Color, ink:Color, size:Float, padX:Float, padY:Float, round:Float):View
		return row(key, [kv("t", text(label, size, ink))], function(s) {
			s.padding = new Insets(padX, padY, padX, padY);
			s.background = fill;
			radius(s, round);
		});

	/** Tap, and optionally long-press, on any view. The detector fills the width of its parent. */
	public static function tappable(key:String, child:View, onTap:Void->Void, ?onLong:Void->Void):View {
		var style = new LayoutStyle();
		style.width = LayoutAxis.stretch();
		var recognizers:Array<haxeon.ui.gestures.GestureRecognizer> = [new TapRecognizer(function(_) onTap())];
		if (onLong != null) recognizers.push(new LongPressRecognizer(function(_) onLong()));
		return new GestureDetector(key, child, recognizers, style);
	}

	/** A tap target that is only as wide as its content. */
	public static function tappableFit(key:String, child:View, onTap:Void->Void):View
		return new GestureDetector(key, child, [new TapRecognizer(function(_) onTap())]);

	public static function icon(key:String, name:IconName, size:Float, color:Color):View
		return new Icon(key, name, size, color);

	/** "now", "5m", "3h", "2d" from milliseconds since the epoch. */
	public static function age(lastActive:Float):String {
		if (lastActive <= 0) return "";
		var seconds = (Date.now().getTime() - lastActive) / 1000.0;
		if (seconds < 60) return "now";
		if (seconds < 3600) return Std.int(seconds / 60) + "m";
		if (seconds < 86400) return Std.int(seconds / 3600) + "h";
		return Std.int(seconds / 86400) + "d";
	}

	/** Cuts a long name so a one-line label cannot push its row wider than the screen. */
	public static function clip(value:String, limit:Int):String
		return value.length <= limit ? value : value.substr(0, limit - 1) + "…";
}
