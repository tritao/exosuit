package ui;

import haxe.crypto.Sha256;
import haxeon.ui.Color;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.LayoutVisualKind;
import haxeon.ui.Path;
import haxeon.ui.PathBuilder;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Key;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.View;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.controls.Button;
import haxeon.ui.widgets.layout.Column;
import haxeon.ui.widgets.text.Text;
import workspace.client.SessionSvg;

/** Opt-in SVG geometry preview; unsupported content is never partially rendered. */
class SessionSvgView implements View {
 final key:String; final source:String; final frame:Void->Void;
 public function new(key:String, source:String, frame:Void->Void) {this.key=key;this.source=source;this.frame=frame;}
 public function build(context:BuildContext):RenderNode {
  return context.withScope(new Key(key), function() {
   var state = context.resourceState(context.id("svg:" + Sha256.encode(source)), function() return new SvgState(), function(v) v.dispose()).value;
   var rows:Array<KeyedView> = [];
   if (state.document == null && state.error == null) rows.push(new KeyedView("show",new Button("Preview SVG",null,function() {
    var doc = SessionSvg.parse(source);
    if (doc == null) state.error = "SVG preview supports basic shapes and paths only. View source for this SVG.";
    else try { state.load(doc); } catch (_:Dynamic) { state.dispose(); state.error = "Unable to render this SVG. View source instead."; }
    frame();
   }, key + "-preview")));
   if (state.error != null) rows.push(new KeyedView("error",new Text(state.error)));
   if (state.document != null) {
    var doc = state.document, style = new LayoutStyle(); style.width=LayoutAxis.grow();style.height=LayoutAxis.fixed(240);
    style.background=context.theme.tokens.surfaceSunken;style.clipHorizontal=true;style.clipVertical=true;
    var node=new RenderNode(context.id("svg-image"),LayoutVisualKind.Custom,style);
    node.semantics=new haxeon.ui.semantics.Semantics(haxeon.ui.semantics.AccessibilityRole.Image,"SVG preview");
    node.onPaint(function(canvas,geometry) {
     var scale=Math.min((geometry.width-16)/doc.width,(geometry.height-16)/doc.height);
     if (scale <= 0) return;
     canvas.save(); canvas.translate((geometry.width-doc.width*scale)/2,(geometry.height-doc.height*scale)/2);
     canvas.scale(scale,scale);canvas.translate(-doc.x,-doc.y);
     for (i in 0...doc.shapes.length) {
      var shape=doc.shapes[i], path=state.paths[i];
      if (shape.fill != null) canvas.fillTransient(path,rgb(shape.fill));
      if (shape.stroke != null && shape.strokeWidth > 0) canvas.strokeTransient(path,rgb(shape.stroke),shape.strokeWidth);
     }
     canvas.restore();
    }, key + ":" + Sha256.encode(source));
    rows.push(new KeyedView("image",new SvgNode(node)));
   }
   var layout=new LayoutStyle();layout.width=LayoutAxis.grow();layout.childGap=8;
   return new Column(key+"-svg",rows,layout).build(context);
  });
 }
 static function rgb(value:Int):Color return Color.fromBytes((value >> 16)&255,(value >> 8)&255,value&255);
}
private class SvgState {
 public var document:Null<workspace.client.SessionSvg.SvgDocument>;
 public var paths:Array<Path> = [];
 public var error:Null<String>;
 public function new() {}
 public function load(doc:workspace.client.SessionSvg.SvgDocument):Void {
  for (shape in doc.shapes) {
   var builder=new PathBuilder();
   for (cmd in shape.commands) {var v=cmd.values; switch cmd.op {
    case "M": builder.moveTo(v[0],v[1]);
    case "L": builder.lineTo(v[0],v[1]);
    case "Q": builder.quadraticTo(v[0],v[1],v[2],v[3]);
    case "C": builder.cubicTo(v[0],v[1],v[2],v[3],v[4],v[5]);
    case "Z": builder.close();
    default: throw "Unsupported path";
   }}
   paths.push(builder.build());
  }
  document=doc;
 }
 public function dispose():Void {for (path in paths) path.dispose();paths=[];document=null;}
}
private class SvgNode implements View {
 final node:RenderNode; public function new(node:RenderNode) this.node=node;
 public function build(context:BuildContext):RenderNode return node;
}
