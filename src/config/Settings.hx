package config;

class Settings {
	public var fontPath:String = ApplicationPaths.resource("data/fonts/JetBrainsMono-Regular.ttf");
	public var fontFallbackPaths:Array<String> = defaultFontFallbackPaths();

	/** Small application-owned symbol coverage, independent of platform font discovery. */
	public static function bundledFontFallbackPaths():Array<String>
		return [ApplicationPaths.resource("data/fonts/NotoSansSymbols2-Regular.ttf")];

	static function defaultFontFallbackPaths():Array<String> {
		var paths = bundledFontFallbackPaths();
		paths.push("/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc");
		paths.push("/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf");
		paths.push("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf");
		return paths;
	}
	public var applicationZoom:Int = 100;
	/** Codex defaults used when Workbench creates a new thread. */
	public var codexDefaultModel:String = "";
	public var codexDefaultEffort:String = "model-default";
	public var codexDefaultPermissions:String = "workspace-write";
	public var fontSize:Int = 15;
	public var explorerFontSize:Int = 15;
	public var sidebarWidth:Int = 220;
	public var scrollbarVisibility:String = "auto";
	public var tabTooltipDelay:Float = 0.8;
	public var minimapEnabled:Bool = true;
	public var wordWrap:Bool = false;
	public var renderWhitespace:String = "selection";
	public var terminalFontSize:Int = 14;
	public var tabWidth:Int = 4;
	/** Effective indentation step; may differ from hard-tab display width. */
	public var indentSize:Int = 4;
	public var insertSpaces:Bool = true;
	public var scrollAnimationType:String = "smooth";
	public var scrollAnimationDuration:Float = 0.12;
	public var haxeonEnabled:Bool = true;
	public var haxeonCommand:Array<String> = [];
	public var haxeonVerbose:Bool = false;
	public var excludedNames:Array<String> = [".git", ".hg", ".svn", ".devstack", "build", "out", "node_modules"];
	public var searchCaseSensitive:Bool = false;
	public var searchWholeWord:Bool = false;
	public var searchMaxResults:Int = 10000;
	public var editorBackground:Int = style.WorkbenchColors.opaque(style.WorkbenchColors.darkEditorBackground);
	public var editorForeground:Int = style.WorkbenchColors.opaque(style.WorkbenchColors.darkForeground);
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
		result.applicationZoom = applicationZoom;
		result.codexDefaultModel = codexDefaultModel;
		result.codexDefaultEffort = codexDefaultEffort;
		result.codexDefaultPermissions = codexDefaultPermissions;
		result.fontSize = fontSize;
		result.explorerFontSize = explorerFontSize;
		result.sidebarWidth = sidebarWidth;
		result.scrollbarVisibility = scrollbarVisibility;
		result.tabTooltipDelay = tabTooltipDelay;
		result.minimapEnabled = minimapEnabled;
		result.wordWrap = wordWrap;
		result.renderWhitespace = renderWhitespace;
		result.terminalFontSize = terminalFontSize;
		result.tabWidth = tabWidth;
		result.indentSize = indentSize;
		result.insertSpaces = insertSpaces;
		result.scrollAnimationType = scrollAnimationType;
		result.scrollAnimationDuration = scrollAnimationDuration;
		result.haxeonEnabled = haxeonEnabled;
		result.haxeonCommand = copyStrings(haxeonCommand);
		result.haxeonVerbose = haxeonVerbose;
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
