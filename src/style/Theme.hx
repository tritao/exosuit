package style;

import haxe.Json;
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
	public var styleRevision(default, null):Int = 0;
	final textMateStyles:Array<TextMateScopeStyle> = [];

	public function new() {}

	public function tokenColor(kind:Int, ?scopes:Array<String>):Int {
		if (scopes != null && scopes.length > 0) {
			var selected:Null<TextMateScopeStyle> = null, bestSpecificity = -1;
			for (style in textMateStyles) {
				var specificity = selectorSpecificity(style.selector, scopes);
				if (specificity >= 0 && specificity >= bestSpecificity) {
					selected = style;
					bestSpecificity = specificity;
				}
			}
			if (selected != null) return selected.color;
		}
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
	}

	/** Appends TextMate theme foreground selectors in source order. */
	public function addTextMateTheme(source:String):Void {
		var raw:Dynamic = Json.parse(source), settings:Dynamic = Reflect.field(raw, "settings");
		if (settings == null || !Std.isOfType(settings, Array)) throw "TextMate theme requires a settings array";
		for (entry in (cast settings:Array<Dynamic>)) {
			var values:Dynamic = Reflect.field(entry, "settings"), foreground = values == null ? null : Reflect.field(values, "foreground");
			if (!Std.isOfType(foreground, String)) continue;
			var color = parseColor(cast foreground), scope:Dynamic = Reflect.field(entry, "scope");
			if (scope == null) {
				textMateStyles.push(new TextMateScopeStyle("", color));
			} else if (Std.isOfType(scope, String)) {
				textMateStyles.push(new TextMateScopeStyle(cast scope, color));
			} else if (Std.isOfType(scope, Array)) {
				for (selector in (cast scope:Array<Dynamic>))
					if (Std.isOfType(selector, String)) textMateStyles.push(new TextMateScopeStyle(cast selector, color));
			}
		}
		styleRevision++;
	}

	static function parseColor(value:String):Int {
		if (value.length != 7 && value.length != 9 || value.charAt(0) != "#")
			throw 'Invalid TextMate theme color "$value"';
		var red = Std.parseInt("0x" + value.substr(1, 2));
		var green = Std.parseInt("0x" + value.substr(3, 2));
		var blue = Std.parseInt("0x" + value.substr(5, 2));
		var alpha = value.length == 9 ? Std.parseInt("0x" + value.substr(7, 2)) : 255;
		if (red == null || green == null || blue == null || alpha == null) throw 'Invalid TextMate theme color "$value"';
		return (red << 24) | (green << 16) | (blue << 8) | alpha;
	}

	static function selectorSpecificity(selector:String, scopes:Array<String>):Int {
		if (selector.length == 0) return 0;
		var best = -1;
		for (alternative in selector.split(",")) {
			var parts = StringTools.trim(alternative).split(" "), excluded = false, required:Array<String> = [];
			for (part in parts) {
				part = StringTools.trim(part);
				if (part.length == 0) continue;
				if (StringTools.startsWith(part, "-")) {
					var exclusionSelector = part.substr(1);
					for (scope in scopes) if (scopeMatches(scope, exclusionSelector)) excluded = true;
				} else required.push(part);
			}
			if (excluded) continue;
			var cursor = scopes.length - 1, matched = true, specificity = 0;
			var index = required.length;
			while (index > 0) {
				var part = required[--index], found = false;
				while (cursor >= 0) {
					if (scopeMatches(scopes[cursor], part)) {
						found = true;
						cursor--;
						break;
					}
					cursor--;
				}
				if (!found) {
					matched = false;
					break;
				}
				specificity += part.split(".").length * 4 + 1;
			}
			if (matched && specificity > best) best = specificity;
		}
		return best;
	}

	static function scopeMatches(scope:String, selector:String):Bool
		return selector.length > 0 && (scope == selector || StringTools.startsWith(scope, selector + "."));

	/** Standard LSP entity names; unfamiliar categories retain syntax colors. */
	public function semanticColor(type:String, modifiers:Array<String>):Null<Int> {
		return switch type {
			case "namespace": lightSyntax ? 0x795e26ff : 0xd7ba7dff;
			case "type", "class", "enum", "interface", "struct", "typeParameter": tokenColor(HighlightToken.TYPE);
			case "function", "method", "macro": lightSyntax ? 0x795e26ff : 0xdcdcaaff;
			case "parameter": lightSyntax ? 0x8a4b08ff : 0xd19a66ff;
			case "variable", "property", "event": modifiers.indexOf("readonly") >= 0
				? (lightSyntax ? 0x005f9eff : 0x4fc1ffff) : (lightSyntax ? 0x174a8bff : 0x9cdcfeff);
			case "enumMember": lightSyntax ? 0x005f9eff : 0x4fc1ffff;
			case "keyword", "modifier": tokenColor(HighlightToken.KEYWORD);
			case "comment": tokenColor(HighlightToken.COMMENT);
			case "string", "regexp": tokenColor(HighlightToken.STRING);
			case "number": tokenColor(HighlightToken.NUMBER);
			case "operator": tokenColor(HighlightToken.OPERATOR);
			case "decorator": lightSyntax ? 0x795e26ff : 0xdcdcaaff;
			default: null;
		};
	}

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
