package style;

/** Shared semantic RGB colors. Convert to packed RGBA only at the model boundary. */
class WorkbenchColors {
	public static inline var darkAccent:Int = 0x8caeff;
	public static inline var lightAccent:Int = 0x365fc4;
	public static inline var darkAccentHover:Int = 0xa8c2ff;
	public static inline var lightAccentHover:Int = 0x2d51ad;
	public static inline var darkAccentPressed:Int = 0x7195eb;
	public static inline var lightAccentPressed:Int = 0x24428f;
	public static inline var darkForeground:Int = 0xe6e6e9;
	public static inline var lightForeground:Int = 0x24252b;
	public static inline var darkForegroundMuted:Int = 0xa6a7af;
	public static inline var lightForegroundMuted:Int = 0x5c5e69;
	public static inline var darkForegroundDisabled:Int = 0x7f808a;
	public static inline var lightForegroundDisabled:Int = 0x737580;
	public static inline var darkForegroundOnAccent:Int = 0x11182b;
	public static inline var lightForegroundOnAccent:Int = 0xffffff;
	public static inline var darkSurface:Int = 0x202024;
	public static inline var lightSurface:Int = 0xf3f3f5;
	public static inline var darkSurfaceRaised:Int = 0x29292e;
	public static inline var lightSurfaceRaised:Int = 0xffffff;
	public static inline var darkSurfaceSunken:Int = 0x18181b;
	public static inline var lightSurfaceSunken:Int = 0xffffff;
	public static inline var darkSurfaceHover:Int = 0x333339;
	public static inline var lightSurfaceHover:Int = 0xe7e8ed;
	public static inline var darkDivider:Int = 0x34343a;
	public static inline var lightDivider:Int = 0xdcdde2;
	public static inline var darkBorder:Int = 0x494950;
	public static inline var lightBorder:Int = 0xafb1ba;
	public static inline var darkBorderStrong:Int = 0x696a73;
	public static inline var lightBorderStrong:Int = 0x858792;
	public static inline var darkSelection:Int = 0x344769;
	public static inline var lightSelection:Int = 0xd3dff8;
	public static inline var darkEditorBackground:Int = 0x1b1b1e;
	public static inline var lightEditorBackground:Int = 0xffffff;
	public static inline var lightEditorSurface:Int = 0xf4f4f6;
	public static inline var lightEditorInactive:Int = 0xededf0;
	public static inline var lightEditorHover:Int = 0xe6e7eb;
	public static inline var lightCurrentLine:Int = 0xf4f5f8;
	public static inline var lightSearchMatch:Int = 0xffe5a3;
	public static inline var lightBracketMatch:Int = 0xdce5f8;

	public static inline function opaque(rgb:Int):Int return (rgb << 8) | 0xff;
}
