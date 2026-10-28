package ui;

import haxe.io.Bytes;
import haxeon.ui.Image;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.LayoutVisualKind;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Key;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.View;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.controls.Button;
import haxeon.ui.widgets.layout.Column;
import haxeon.ui.widgets.layout.Row;
import haxeon.ui.widgets.text.Text;

/** Opaque session attachment: fetch only on explicit preview/open. */
class SessionMessageImageView implements View {
 final key:String; final identity:String; final load:((Null<Bytes>,Null<String>)->Void)->Void;
 final open:Null<Bytes->Void>; final frame:Void->Void;
 public function new(key:String,identity:String,load:((Null<Bytes>,Null<String>)->Void)->Void,open:Null<Bytes->Void>,frame:Void->Void) {
  this.key=key;this.identity=identity;this.load=load;this.open=open;this.frame=frame;
 }
 public function build(context:BuildContext):RenderNode return context.withScope(new Key(key),function() {
  var state=context.resourceState(context.id("sent-image"),function() return new SentImageState(),function(value) value.dispose()).value;
  state.target(identity);
  function request(forOpen:Bool):Void {
   if(state.loading) return;
   state.loading=true;state.error=null;var generation=++state.generation, finished=false;
   try load(function(bytes,error) {
    if(finished || state.closed || state.generation!=generation) return;
    finished=true;
    state.loading=false;
    try {
     if(error!=null) throw error;
     if(bytes==null) throw "This sent image is no longer available";
     if(forOpen) {
      if(open==null) throw "Opening this image is unavailable";
      open(bytes);
     } else {
      var image=SessionImageProbe.decode(bytes);
      if(image==null) throw "Unsupported image or dimensions exceed 4096 pixels";
      if(state.image!=null) state.image.dispose();state.image=image;
     }
    } catch(problem:Dynamic) state.error=Std.string(problem);
    frame();
   }) catch(problem:Dynamic) {state.loading=false;state.error=Std.string(problem);}
   frame();
  }
  var controls:Array<KeyedView>=[];
  if(state.image==null) {
   var preview=new Button(state.loading ? "Loading image…" : state.error==null ? "Preview image" : "Retry image preview",null,function() request(false),key+"-preview");
   preview.enabled=!state.loading;controls.push(new KeyedView("preview",preview));
  }
  if(open!=null) {
   var openButton=new Button("Open image",null,function() request(true),key+"-open");
   openButton.enabled=!state.loading;controls.push(new KeyedView("open",openButton));
  }
  var rows:Array<KeyedView>=[new KeyedView("caption",new Text("Sent image"))];
  if(state.image!=null) {
   var image:Image=cast state.image,style=new LayoutStyle();style.width=LayoutAxis.grow();style.height=LayoutAxis.fixed(160);
   style.clipHorizontal=true;style.clipVertical=true;style.background=context.theme.tokens.surfaceSunken;
   var raster=new RenderNode(context.id("raster"),LayoutVisualKind.Custom,style);
   raster.semantics=new haxeon.ui.semantics.Semantics(haxeon.ui.semantics.AccessibilityRole.Image,"Sent image, "+image.width+" by "+image.height+" pixels");
   raster.onPaint(function(canvas,geometry) {if(!image.isDisposed()) canvas.drawImage(image,ImagePreviewView.fittedBounds(image.width,image.height,geometry.width,geometry.height));},key+":"+image.identity);
   rows.push(new KeyedView("image",new SentRaster(raster)));
  }
  if(state.error!=null) rows.push(new KeyedView("error",new Text(state.error)));
  var bar=new LayoutStyle();bar.width=LayoutAxis.grow();bar.childGap=8;
  if(controls.length>0) rows.push(new KeyedView("controls",new Row(key+"-controls",controls,bar)));
  var layout=new LayoutStyle();layout.width=LayoutAxis.grow();layout.childGap=6;
  return new Column(key+"-attachment",rows,layout).build(context);
 });
}
private class SentImageState {
 public var image:Null<Image>;public var error:Null<String>;public var loading=false;public var closed=false;public var generation=0;
 var identity:Null<String>;
 public function new() {}
 public function target(value:String):Void {
  if(identity==value) return;identity=value;generation++;loading=false;error=null;
  if(image!=null) image.dispose();image=null;
 }
 public function dispose():Void {closed=true;generation++;if(image!=null) image.dispose();image=null;}
}
private class SentRaster implements View {
 final node:RenderNode;
 public function new(node:RenderNode) this.node=node;
 public function build(context:BuildContext):RenderNode return node;
}
