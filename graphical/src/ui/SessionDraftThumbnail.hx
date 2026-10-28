package ui;

import haxe.io.Bytes;
import haxeon.ui.Image;
import haxeon.ui.ImageFormat;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.LayoutVisualKind;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Key;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.View;
import haxeon.ui.widgets.ImageView;
import haxeon.ui.widgets.ImageFit;

/** The keyed UI resource owns the decoded texture until this draft leaves the tree. */
class SessionDraftThumbnail implements View {
 final key:String; final name:String; final bytes:Bytes;
 public function new(key:String, name:String, bytes:Bytes) { this.key=key; this.name=name; this.bytes=bytes; }
 public function build(context:BuildContext):RenderNode {
  return context.withScope(new Key(key), function() {
   var state = context.resourceState(context.id("draft-thumbnail"), function() return new SessionDraftThumbnailState(bytes), function(value) value.dispose()).value;
   var style = new LayoutStyle(); style.width = LayoutAxis.fixed(48); style.height = LayoutAxis.fixed(48);
   style.background = context.theme.tokens.surfaceSunken;
   if (state.image == null) return new RenderNode(context.id("thumbnail-unavailable"), LayoutVisualKind.Box, style);
   var view = new ImageView("image", cast state.image, name + " preview", style); view.fit = ImageFit.Contain;
   return view.build(context);
  });
 }
}
private class SessionDraftThumbnailState {
 public var image:Null<Image>;
 public function new(bytes:Bytes) {
  try {
   var pixels = Bytes.alloc(96*96*4);
   var size = decodeDraftThumbnail(DraftThumbnailBytes.data(bytes), bytes.length, DraftThumbnailBytes.data(pixels), pixels.length);
   var width = size >>> 16, height = size & 65535;
   if (width > 0 && height > 0 && width <= 96 && height <= 96)
    image = Image.create(width, height, ImageFormat.RGBA8, pixels.sub(0,width*height*4));
  } catch (_:Dynamic) image = null;
 }
 public function dispose():Void { if (image != null) image.dispose(); image = null; }
}
@:cNative("exosuit_clipboard", "exosuit_image_thumbnail", "11,5,11,5>5")
extern function decodeDraftThumbnail(input:hl.Bytes, length:Int, output:hl.Bytes, capacity:Int):Int;
private extern class DraftThumbnailBytes {
 @:hlNative("haxeon_runtime", "__bytes_get_data") public static function data(value:Bytes):hl.Bytes;
}
