package ui;

import haxeon.ui.Image;
import haxeon.ui.Insets;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.LayoutVisualKind;
import haxeon.ui.Rect;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Key;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.View;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.controls.Button;
import haxeon.ui.widgets.layout.Column;
import haxeon.ui.widgets.text.Text;

/** User-initiated, bounded local raster preview. The host owns path authorization. */
class SessionImageView implements View {
 final key:String; final alt:String; final destination:String;
 final resolvePath:String->Null<String>; final openLink:String->Void; final frame:Void->Void;
 public function new(key:String, alt:String, destination:String, resolvePath:String->Null<String>, openLink:String->Void, frame:Void->Void) {
  this.key=key; this.alt=alt; this.destination=destination; this.resolvePath=resolvePath; this.openLink=openLink; this.frame=frame;
 }
 public function build(context:BuildContext):RenderNode {
  return context.withScope(new Key(key), function() {
   var state = context.resourceState(context.id("image-resource:" + destination), function() return new SessionImageState(), function(value) value.dispose()).value;
   var rows:Array<KeyedView> = [];
   var label = alt == "" ? "Image" : alt;
   rows.push(new KeyedView("caption", new Text(label)));
   if (state.image == null && state.error == null) {
    rows.push(new KeyedView("preview", new Button("Preview image", null, function() {
     try {
      var path = resolvePath == null ? null : resolvePath(destination);
      if (path == null) throw "Image preview is unavailable for this location";
      var metadata = sys.FileSystem.metadata(path);
      if (metadata == null || metadata.size <= 0 || metadata.size > SessionImageProbe.MAX_BYTES) throw "Image exceeds the 4 MiB preview limit";
      var bytes = SessionImageProbe.readBounded(path);
      var size = SessionImageProbe.dimensions(bytes);
      if (size == null) throw "Unsupported image or dimensions exceed 4096 pixels";
      var loaded = Image.loadFile(path);
      if (loaded.width != size.width || loaded.height != size.height) { loaded.dispose(); throw "Image changed while loading"; }
      state.image = loaded;
     } catch (error:Dynamic) state.error = Std.string(error);
     frame();
    }, key + "-preview")));
   }
   if (state.error != null) rows.push(new KeyedView("error", new Text(state.error)));
   if (state.image != null) {
    var image:Image = cast state.image;
    var style = new LayoutStyle(); style.width = LayoutAxis.grow(); style.height = LayoutAxis.fixed(240);
    style.clipHorizontal = true; style.clipVertical = true; style.background = context.theme.tokens.surfaceSunken;
    var node = new RenderNode(context.id("raster"), LayoutVisualKind.Custom, style);
    node.semantics = new haxeon.ui.semantics.Semantics(haxeon.ui.semantics.AccessibilityRole.Image, label + ", " + image.width + " by " + image.height + " pixels");
    node.onPaint(function(canvas, geometry) {
     if (!image.isDisposed()) canvas.drawImage(image, ImagePreviewView.fittedBounds(image.width, image.height, geometry.width, geometry.height));
    }, key + ":" + image.identity);
    rows.push(new KeyedView("image", new SessionImageNode(node)));
   }
   if (openLink != null) rows.push(new KeyedView("open", new Button("Open image", null, function() openLink(destination), key + "-open")));
   var layout = new LayoutStyle(); layout.width = LayoutAxis.grow(); layout.childGap = 8; layout.padding = new Insets(0, 4, 0, 4);
   return new Column(key + "-image", rows, layout).build(context);
  });
 }
}
private class SessionImageState {
 public var image:Null<Image>; public var error:Null<String>;
 public function new() {}
 public function dispose():Void { if (image != null) image.dispose(); image = null; }
}
private class SessionImageNode implements View {
 final node:RenderNode;
 public function new(node:RenderNode) this.node = node;
 public function build(context:BuildContext):RenderNode return node;
}
