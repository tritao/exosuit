package ui;

import haxeon.ui.Color;
import haxeon.ui.FontCollection;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.LayoutVisualKind;
import haxeon.ui.ParagraphStyle;
import haxeon.ui.TextLayout;
import haxeon.ui.TextLayout.TextPosition;
import haxeon.ui.TextStyle;
import haxeon.ui.TextWrap;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.View;
import haxeon.ui.semantics.AccessibilityRole;
import haxeon.ui.semantics.Semantics;

/** Shared real font faces; mounted Markdown views hold leases and release the pool on unmount. */
class MarkdownEmphasis {
 static var leases:Int = 0;
 static var faces:Map<String, FontCollection> = [];
 static var unavailable:Map<String, Bool> = [];
 public static function acquire():MarkdownEmphasis { leases++; return new MarkdownEmphasis(); }
 function new() {}
 public function dispose():Void {
  leases--;
  if (leases == 0) { for (face in faces) face.dispose(); faces = []; unavailable = []; }
 }
 public function face(bold:Bool, italic:Bool):Null<FontCollection> {
  var key = (bold ? "bold" : "") + (italic ? "italic" : "");
  if (key == "" || unavailable.exists(key)) return null;
  var cached = faces.get(key); if (cached != null) return cached;
  var name = bold && italic ? "Bold Italic" : bold ? "Bold" : "Italic";
  var candidates:Array<String> = [];
  try candidates = switch Sys.systemName() {
   case "Windows":
    var windir = Sys.getEnv("WINDIR"); if (windir == null || windir == "") windir = "C:/Windows";
    [windir + "/Fonts/" + (bold && italic ? "segoeuiz.ttf" : bold ? "segoeuib.ttf" : "segoeuii.ttf")];
   case "Mac": ["/System/Library/Fonts/Supplemental/Arial " + name + ".ttf"];
   default: ["/usr/share/fonts/truetype/dejavu/DejaVuSans-" + (bold && italic ? "BoldOblique" : bold ? "Bold" : "Oblique") + ".ttf"];
  } catch (_:Dynamic) { unavailable.set(key, true); return null; }
  for (path in candidates) {
   var exists = false;
   try exists = sys.FileSystem.exists(path) catch (_:Dynamic) {}
   if (!exists) continue;
   var fonts:Null<FontCollection> = null;
   try { fonts = FontCollection.create(); fonts.add(path); fonts.addSystemFallbacks(); faces.set(key, fonts); return fonts; }
   catch (_:Dynamic) { if (fonts != null) fonts.dispose(); }
  }
  unavailable.set(key, true); return null;
 }
}

/** A measured, accessible text run using an isolated emphasized font collection. */
class MarkdownEmphasisText implements View {
 final text:String; final size:Float; final color:Color; final fonts:FontCollection; final variant:String;
 public function new(text:String, size:Float, color:Color, fonts:FontCollection, variant:String) {
  this.text=text; this.size=size; this.color=color; this.fonts=fonts; this.variant=variant;
 }
 public function build(context:BuildContext):RenderNode {
  var state = context.resourceState(context.id("emphasis-run"), function() return new MarkdownRunState(), function(value) value.dispose()).value;
  var signature = variant + ":" + text + "\x01" + size + ":" + color.red + ":" + color.green + ":" + color.blue + ":" + color.alpha;
  if (state.signature != signature || state.fonts != fonts) {
   state.dispose(); state.signature=signature; state.fonts=fonts;
   var created=TextLayout.create(fonts,text,100000,new TextStyle(size),new ParagraphStyle(TextWrap.None));
   state.layout=created;
   created.setColor(color);
   var bytes=haxe.io.Bytes.ofString(text), count=0;
   for (index in 0...bytes.length) if ((bytes.get(index) & 0xc0) != 0x80) count++;
   var minX=0.0, maxX=0.0;
   for (index in 0...count + 1) {
    var x=created.caret(new TextPosition(index,0)).x;
    minX=Math.min(minX,x); maxX=Math.max(maxX,x);
   }
   state.offset=minX; state.width=Math.max(0,maxX-minX);
  }
  var layout:TextLayout = cast state.layout, metrics=layout.measure();
  var offset = state.offset;
  var style=new LayoutStyle(); style.width=LayoutAxis.fixed(state.width); style.height=LayoutAxis.fixed(metrics.height);
  var node=new RenderNode(context.id("emphasis-text"),LayoutVisualKind.Custom,style);
  node.setStyleIdentity("markdown-emphasis",null,null,null,["markdown-emphasis"]);
  node.semantics=new Semantics(AccessibilityRole.Text,text);
  node.onPaint(function(canvas,_) canvas.drawText(layout,-offset,0),"markdown-emphasis:" + signature);
  return node;
 }
}

private class MarkdownRunState {
 public var signature:String = "";
 public var fonts:Null<FontCollection>;
 public var layout:Null<TextLayout>;
 public var offset:Float = 0;
 public var width:Float = 0;
 public function new() {}
 public function dispose():Void { if (layout != null) layout.dispose(); layout=null; fonts=null; signature=""; }
}
