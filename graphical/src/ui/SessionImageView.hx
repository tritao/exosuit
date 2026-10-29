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
 final loadImage:Null<(String, (Null<haxe.io.Bytes>, Null<String>)->Void)->Void>;
 public function new(key:String, alt:String, destination:String, resolvePath:String->Null<String>, openLink:String->Void, frame:Void->Void,
   ?loadImage:(String, (Null<haxe.io.Bytes>, Null<String>)->Void)->Void) {
  this.key=key; this.alt=alt; this.destination=destination; this.resolvePath=resolvePath; this.openLink=openLink; this.frame=frame; this.loadImage=loadImage;
 }
 public function build(context:BuildContext):RenderNode {
  return context.withScope(new Key(key), function() {
   var state = context.resourceState(context.id("image-resource"), function() return new SessionImageState(), function(value) value.dispose()).value;
   state.target(destination);
   var rows:Array<KeyedView> = [];
   var label = alt == "" ? "Image" : alt;
   rows.push(new KeyedView("caption", new Text(label)));
   var data = StringTools.startsWith(destination.toLowerCase(),"data:");
   var web = ~/^https?:\/\//i.match(destination);
   if (state.image == null) {
    var preview = new Button(state.loading ? "Loading image…" : state.error == null ? "Preview image" : "Retry image preview", null, function() {
     if (state.loading) return;
     state.error=null; state.loading=true; var generation=++state.generation;
     function finish(bytes:Null<haxe.io.Bytes>, error:Null<String>):Void {
      if (state.closed || state.generation != generation) return;
      state.loading=false;
      try {
       if (error != null) throw error;
       if (bytes == null) throw "Image preview is unavailable for this location";
       var loaded=SessionImageProbe.decode(bytes);
       if (loaded == null) throw "Unsupported image or dimensions exceed 4096 pixels";
       state.image=loaded;
      } catch (problem:Dynamic) state.error=Std.string(problem);
      frame();
     }
     if (data) { var bytes=SessionImageProbe.dataUrl(destination); finish(bytes,bytes == null ? "Invalid or unsupported image data" : null); return; }
     if (web) { finish(null,"External image previews are unavailable"); return; }
     if (loadImage != null) {
      var loader:(String, (Null<haxe.io.Bytes>, Null<String>)->Void)->Void=cast loadImage;
      try loader(destination,finish) catch (problem:Dynamic) finish(null,Std.string(problem));
      frame(); return;
     }
     try {
      var path=resolvePath == null ? null : resolvePath(destination);
      if (path == null) throw "Image preview is unavailable for this location";
      finish(SessionImageProbe.readBounded(path),null);
     } catch (problem:Dynamic) finish(null,Std.string(problem));
    },key+"-preview");
    preview.enabled=!state.loading;
    rows.push(new KeyedView("preview",preview));
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
   if (openLink != null && !data) rows.push(new KeyedView("open", new Button("Open image", null, function() openLink(destination), key + "-open")));
   var layout = new LayoutStyle(); layout.width = LayoutAxis.grow(); layout.childGap = 8; layout.padding = new Insets(0, 4, 0, 4);
   return new Column(key + "-image", rows, layout).build(context);
  });
 }
}
private class SessionImageState {
 public var image:Null<Image>; public var error:Null<String>;
 public var loading:Bool=false; public var closed:Bool=false; public var generation:Int=0;
 var destination:Null<String>;
 public function new() {}
 public function target(next:String):Void {
  if (destination == next) return;
  destination=next; generation++; loading=false; error=null;
  if (image != null) image.dispose(); image=null;
 }
 public function dispose():Void { closed=true; generation++; if (image != null) image.dispose(); image = null; }
}
private class SessionImageNode implements View {
 final node:RenderNode;
 public function new(node:RenderNode) this.node = node;
 public function build(context:BuildContext):RenderNode return node;
}
