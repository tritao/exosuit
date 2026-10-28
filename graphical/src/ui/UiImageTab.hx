package ui;

import haxeon.ui.Image;

/** Read-only local image tab. Its decoded resource lives until the tab closes. */
class UiImageTab extends view.View {
	public final id:String;
	public final path:String;
	public final image:Image;
	public final sizeBytes:Int;
	public final remote:Bool;
	public var preview:Bool;

	public static function supports(path:String):Bool {
		var name = haxe.io.Path.withoutDirectory(path);
		var dot = name.lastIndexOf(".");
		if (dot < 0) return false;
		var extension = name.substring(dot + 1).toLowerCase();
		return extension == "png" || extension == "jpg" || extension == "jpeg" ||
			extension == "bmp" || extension == "gif" || extension == "tga";
	}

	public function new(path:String, preview:Bool, ?remoteImage:Image, ?remoteBytes:Int = 0, ?remoteId:String, ?sourceLabel:String = "remote") {
		super(haxe.io.Path.withoutDirectory(path) + (remoteImage == null ? "" : " · " + sourceLabel));
		this.path = path;
		this.remote = remoteImage != null;
		this.id = remoteImage == null ? "image:" + path : remoteId;
		this.preview = preview;
		if (remoteImage != null) {
			this.sizeBytes = remoteBytes;
			this.image = remoteImage;
			return;
		}
		var metadata = sys.FileSystem.metadata(path);
		if (metadata == null) throw "Could not read image file metadata";
		this.sizeBytes = metadata.size;
		// Decode bytes directly through UIKit, never through the text filesystem API.
		this.image = Image.loadFile(path);
	}

	override public function dispose():Void image.dispose();
}
