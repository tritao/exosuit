package style;

import syntax.HighlightToken;

class Theme {
	public var lightSyntax:Bool = false;
	public var editorBackground:Int = WorkbenchColors.opaque(WorkbenchColors.darkEditorBackground);
	public var editorForeground:Int = WorkbenchColors.opaque(WorkbenchColors.darkForeground);
	public var accent:Int = 0x4f8fccff;
	public var surface:Int = 0x202020ff;
	public var surfaceElevated:Int = 0x252932ff;
	public var surfaceActive:Int = 0x303030ff;
	public var surfaceInactive:Int = 0x222222ff;
	public var surfaceHover:Int = 0x2a2a2aff;
	public var border:Int = 0x111111ff;
	public var divider:Int = 0x101010ff;
	public var foregroundMuted:Int = 0xaaaaaaff;
	public var foregroundSubtle:Int = 0x777777ff;
	public var foregroundDisabled:Int = 0x666666ff;
	public var selection:Int = 0x264f78ff;
	public var currentLine:Int = 0x202020ff;
	public var bracketMatch:Int = 0x3c4b5aff;
	public var searchMatch:Int = 0x6b5b1fff;
	public var caret:Int = 0xffffffff;
	public var overlay:Int = 0x00000066;
	public var information:Int = 0x29435cff;
	public var warning:Int = 0x66521fff;
	public var error:Int = 0x4c3030ff;
	public var diagnosticError:Int = 0xe06c75ff;
	public var diagnosticWarning:Int = 0xe5c07bff;
	public var scrollbar:Int = 0x606060ff;

	public function new() {}

	public function tokenColor(kind:Int):Int
		if (lightSyntax) return switch kind {
			case HighlightToken.KEYWORD: 0x7b3fb3ff;
			case HighlightToken.TYPE: 0x146b8aff;
			case HighlightToken.NUMBER: 0x9b4d13ff;
			case HighlightToken.STRING: 0x247a37ff;
			case HighlightToken.COMMENT: 0x66758aff;
			case HighlightToken.OPERATOR: 0x425064ff;
			case HighlightToken.LITERAL: 0xb33e4bff;
			default: editorForeground;
		};
		else return switch kind {
			case HighlightToken.KEYWORD: 0xc678ddff;
			case HighlightToken.TYPE: 0x56b6c2ff;
			case HighlightToken.NUMBER: 0xd19a66ff;
			case HighlightToken.STRING: 0x98c379ff;
			case HighlightToken.COMMENT: 0x7f848eff;
			case HighlightToken.OPERATOR: 0xabb2bfff;
			case HighlightToken.LITERAL: 0xe06c75ff;
			default: editorForeground;
		};

	public static function contrastRatio(first:Int, second:Int):Float {
		var left = luminance(first), right = luminance(second), lighter = left > right ? left : right, darker = left > right ? right : left;
		return (lighter + 0.05) / (darker + 0.05);
	}

	static function luminance(color:Int):Float
		return 0.2126 * channel((color >>> 24) & 255) + 0.7152 * channel((color >>> 16) & 255) + 0.0722 * channel((color >>> 8) & 255);

	static function channel(value:Int):Float {
		var normalized = value / 255.0;
		return normalized <= 0.04045 ? normalized / 12.92 : Math.pow((normalized + 0.055) / 1.055, 2.4);
	}
}
