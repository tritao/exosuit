package ui;

import haxeon.ui.Image;

/** Read-only local image tab. Its decoded resource lives until the tab closes. */
class UiImageTab extends view.View {
	public final id:String;
	public final path:String;
	public final image:Image;
	public var preview:Bool;

	public static function supports(path:String):Bool {
		var name = haxe.io.Path.withoutDirectory(path);
		var dot = name.lastIndexOf(".");
		if (dot < 0) return false;
		var extension = name.substring(dot + 1).toLowerCase();
		return extension == "png" || extension == "jpg" || extension == "jpeg" ||
			extension == "bmp" || extension == "gif" || extension == "tga";
	}

	public function new(path:String, preview:Bool) {
		super(haxe.io.Path.withoutDirectory(path));
		this.path = path;
		this.id = "image:" + path;
		this.preview = preview;
		// Decode bytes directly through UIKit, never through the text filesystem API.
		this.image = Image.loadFile(path);
	}

	override public function dispose():Void image.dispose();
}
