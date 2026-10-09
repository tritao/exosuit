package style;

/** Shared semantic RGB colors. Convert to packed RGBA only at the model boundary. */
class WorkbenchColors {
	public static inline var darkAccent:Int = 0x78aef8;
	public static inline var lightAccent:Int = 0x2866b2;
	public static inline var darkAccentHover:Int = 0x91bfff;
	public static inline var lightAccentHover:Int = 0x1d579d;
	public static inline var darkAccentPressed:Int = 0x5e96df;
	public static inline var lightAccentPressed:Int = 0x18477f;
	public static inline var darkForeground:Int = 0xdce3ec;
	public static inline var lightForeground:Int = 0x202a36;
	public static inline var darkForegroundMuted:Int = 0xa6b2c1;
	public static inline var lightForegroundMuted:Int = 0x536174;
	public static inline var darkForegroundDisabled:Int = 0x8793a3;
	public static inline var lightForegroundDisabled:Int = 0x687589;
	public static inline var darkForegroundOnAccent:Int = 0x14202e;
	public static inline var lightForegroundOnAccent:Int = 0xffffff;
	public static inline var darkSurface:Int = 0x202630;
	public static inline var lightSurface:Int = 0xf4f6fa;
	public static inline var darkSurfaceRaised:Int = 0x262e39;
	public static inline var lightSurfaceRaised:Int = 0xe8edf4;
	public static inline var darkSurfaceSunken:Int = 0x171c23;
	public static inline var lightSurfaceSunken:Int = 0xffffff;
	public static inline var darkSurfaceHover:Int = 0x303b49;
	public static inline var lightSurfaceHover:Int = 0xdce5f1;
	public static inline var darkBorder:Int = 0x526071;
	public static inline var lightBorder:Int = 0x8b9aad;
	public static inline var darkBorderStrong:Int = 0x657489;
	public static inline var lightBorderStrong:Int = 0x718299;
	public static inline var darkSelection:Int = 0x294765;
	public static inline var lightSelection:Int = 0xc6dcf6;
	public static inline var darkEditorBackground:Int = 0x1b212a;
	public static inline var lightEditorBackground:Int = 0xffffff;
	public static inline var lightEditorSurface:Int = 0xf0f4f9;
	public static inline var lightEditorInactive:Int = 0xf4f6fa;
	public static inline var lightEditorHover:Int = 0xe5ecf5;
	public static inline var lightCurrentLine:Int = 0xf1f5fa;
	public static inline var lightSearchMatch:Int = 0xffe7a0;
	public static inline var lightBracketMatch:Int = 0xd7e5f6;

	public static inline function opaque(rgb:Int):Int return (rgb << 8) | 0xff;
}
