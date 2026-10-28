package config;

class Settings {
	/** Shared hover delay for application controls; keep the existing preference key. */
	public static inline final DEFAULT_TOOLTIP_DELAY = 0.8;
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
	public var layoutMode:String = "auto";
	/** Launch mode for newly created agent sessions across providers. */
	public var agentSessionMode:String = "terminal";
	/** Codex defaults used when Workbench creates a new thread. */
	public var codexDefaultModel:String = "";
	public var codexDefaultEffort:String = "model-default";
	public var codexDefaultPermissions:String = "workspace-write";
	public var fontSize:Int = 15;
	public var explorerFontSize:Int = 15;
	public var confirmTrash:Bool = true;
	public var sidebarWidth:Int = 220;
	public var scrollbarVisibility:String = "auto";
	public var tabTooltipDelay:Float = DEFAULT_TOOLTIP_DELAY;
	public var minimapEnabled:Bool = true;
	public var wordWrap:Bool = false;
	public var renderWhitespace:String = "selection";
	public var terminalFontSize:Int = 14;
	/** Command IDs added to terminal application routing; prefix with '-' to keep a default in the shell. */
	public var terminalCommandsToSkipShell:Array<String> = [];
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
	public var scmEnabled:Bool = true;
	public var scmGitPath:String = "";
	public var scmUntrackedLimit:Int = 10000;
	public var scmDiffSizeLimit:Int = 16 * 1024 * 1024;
	public var scmNestedScanDepth:Int = 3;
	public var scmAutoRefresh:Bool = true;
	/** Fetch remotes periodically; disabled until the user opts in. */
	public var scmAutoFetch:Bool = false;
	/** Offer Commit All when no changes are staged. */
	public var scmCommitAllWhenNothingStaged:Bool = false;
	public var scmGutter:Bool = true;
	public var scmExplorerDecorations:Bool = true;
	public var editorBackground:Int = style.WorkbenchColors.opaque(style.WorkbenchColors.darkEditorBackground);
	public var editorForeground:Int = style.WorkbenchColors.opaque(style.WorkbenchColors.darkForeground);
	public var accent:Int = style.WorkbenchColors.opaque(style.WorkbenchColors.darkAccent);
	public var surface:Int = style.WorkbenchColors.opaque(style.WorkbenchColors.darkSurface);
	public var surfaceElevated:Int = style.WorkbenchColors.opaque(style.WorkbenchColors.darkSurfaceRaised);
	public var surfaceActive:Int = style.WorkbenchColors.opaque(style.WorkbenchColors.darkSurfaceHover);
	public var surfaceInactive:Int = style.WorkbenchColors.opaque(style.WorkbenchColors.darkSurfaceSunken);
	public var surfaceHover:Int = style.WorkbenchColors.opaque(style.WorkbenchColors.darkSurfaceHover);
	public var border:Int = style.WorkbenchColors.opaque(style.WorkbenchColors.darkBorder);
	public var divider:Int = style.WorkbenchColors.opaque(style.WorkbenchColors.darkDivider);
	public var foregroundMuted:Int = style.WorkbenchColors.opaque(style.WorkbenchColors.darkForegroundMuted);
	public var foregroundSubtle:Int = style.WorkbenchColors.opaque(style.WorkbenchColors.darkForegroundDisabled);
	public var foregroundDisabled:Int = style.WorkbenchColors.opaque(style.WorkbenchColors.darkForegroundDisabled);
	public var selection:Int = style.WorkbenchColors.opaque(style.WorkbenchColors.darkSelection);
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
		result.layoutMode = layoutMode;
		result.agentSessionMode = agentSessionMode;
		result.codexDefaultModel = codexDefaultModel;
		result.codexDefaultEffort = codexDefaultEffort;
		result.codexDefaultPermissions = codexDefaultPermissions;
		result.fontSize = fontSize;
		result.explorerFontSize = explorerFontSize;
		result.confirmTrash = confirmTrash;
		result.sidebarWidth = sidebarWidth;
		result.scrollbarVisibility = scrollbarVisibility;
		result.tabTooltipDelay = tabTooltipDelay;
		result.minimapEnabled = minimapEnabled;
		result.wordWrap = wordWrap;
		result.renderWhitespace = renderWhitespace;
		result.terminalFontSize = terminalFontSize;
		result.terminalCommandsToSkipShell = copyStrings(terminalCommandsToSkipShell);
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
		result.scmEnabled = scmEnabled;
		result.scmGitPath = scmGitPath;
		result.scmUntrackedLimit = scmUntrackedLimit;
		result.scmDiffSizeLimit = scmDiffSizeLimit;
		result.scmNestedScanDepth = scmNestedScanDepth;
		result.scmAutoRefresh = scmAutoRefresh;
		result.scmAutoFetch = scmAutoFetch;
		result.scmCommitAllWhenNothingStaged = scmCommitAllWhenNothingStaged;
		result.scmGutter = scmGutter;
		result.scmExplorerDecorations = scmExplorerDecorations;
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
