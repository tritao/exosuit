package config;

class Settings {
	public static inline final VERSION = 1;
	public var fontPath:String = ApplicationPaths.resource("data/fonts/JetBrainsMono-Regular.ttf");
	public var fontFallbackPaths:Array<String> = [
		ApplicationPaths.resource("data/fonts/NotoSansSymbols2-Regular.ttf"),
		"/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
		"/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf",
		"/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
	];
	public var fontSize:Int = 15;
	public var sidebarWidth:Int = 220;
	public var tabWidth:Int = 4;
	public var insertSpaces:Bool = true;
	public var excludedNames:Array<String> = [".git", ".hg", ".svn", ".devstack", "build", "out", "node_modules"];
	public var searchCaseSensitive:Bool = false;
	public var searchWholeWord:Bool = false;
	public var searchMaxResults:Int = 10000;
	public var editorBackground:Int = 404232447;
	public var editorForeground:Int = -421075201;
	public var accent:Int = 1334824191;
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
	public var searchMatch:Int = 0x6b5b1fff;
	public var caret:Int = -1;
	public var overlay:Int = 0x00000066;
	public var information:Int = 0x29435cff;
	public var warning:Int = 0x66521fff;
	public var error:Int = 0x4c3030ff;
	public var scrollbar:Int = 0x606060ff;
	public var keybindings:Array<ConfiguredKeyBinding> = [];

	public function new() {}

	public function copy():Settings {
		var result = new Settings();
		result.fontPath = fontPath;
		result.fontFallbackPaths = copyStrings(fontFallbackPaths);
		result.fontSize = fontSize;
		result.sidebarWidth = sidebarWidth;
		result.tabWidth = tabWidth;
		result.insertSpaces = insertSpaces;
		result.excludedNames = copyStrings(excludedNames);
		result.searchCaseSensitive = searchCaseSensitive;
		result.searchWholeWord = searchWholeWord;
		result.searchMaxResults = searchMaxResults;
		result.editorBackground = editorBackground;
		result.editorForeground = editorForeground;
		result.accent = accent;
		result.surface = surface;
		result.surfaceElevated = surfaceElevated;
		result.surfaceActive = surfaceActive;
		result.surfaceInactive = surfaceInactive;
		result.surfaceHover = surfaceHover;
		result.border = border;
		result.divider = divider;
		result.foregroundMuted = foregroundMuted;
		result.foregroundSubtle = foregroundSubtle;
		result.foregroundDisabled = foregroundDisabled;
		result.selection = selection;
		result.searchMatch = searchMatch;
		result.caret = caret;
		result.overlay = overlay;
		result.information = information;
		result.warning = warning;
		result.error = error;
		result.scrollbar = scrollbar;
		result.keybindings = [for (binding in keybindings) binding.copy()];
		return result;
	}

	static function copyStrings(values:Array<String>):Array<String>
		return [for (value in values) value];
}
