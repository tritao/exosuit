package workspace.client;

typedef SvgCommand = { var op:String; var values:Array<Float>; }
typedef SvgShape = { var commands:Array<SvgCommand>; var fill:Null<Int>; var stroke:Null<Int>; var strokeWidth:Float; }
typedef SvgDocument = { var x:Float; var y:Float; var width:Float; var height:Float; var shapes:Array<SvgShape>; }

/** Strict, bounded inert SVG subset. Unknown syntax fails the whole preview. */
class SessionSvg {
 static inline final MAX_SOURCE = 262144;
 static inline final MAX_NODES = 256;
 static inline final MAX_COMMANDS = 4096;
 static var nodes:Int;
 static var commands:Int;
 public static function parse(source:String):Null<SvgDocument> {
  if (source == null || source.length > MAX_SOURCE || source.indexOf("<!") >= 0 || source.indexOf("&") >= 0) return null;
  try {
   var xml = Xml.parse(source), roots = [for (n in xml.elements()) n];
   if (roots.length != 1 || roots[0].nodeName != "svg") return null;
   nodes = 0; commands = 0;
   var root = roots[0], view = root.get("viewBox"), x = 0.0, y = 0.0, width = 0.0, height = 0.0;
   if (view != null) {
    var v = numbers(view); if (v.length != 4) return null;
    x=v[0]; y=v[1]; width=v[2]; height=v[3];
   } else { width = number(root.get("width"), -1); height = number(root.get("height"), -1); }
   if (width <= 0 || height <= 0 || width > 100000 || height > 100000) return null;
   var shapes:Array<SvgShape> = [];
   visit(root, 0, 0x000000, null, 1, shapes);
   if (shapes.length == 0) return null;
   return {x:x,y:y,width:width,height:height,shapes:shapes};
  } catch (_:Dynamic) return null;
 }
 static function number(raw:Null<String>, fallback:Float):Float {
  if (raw == null) return fallback;
  if (!~/^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$/.match(raw)) throw "Invalid number";
  var n = Std.parseFloat(raw); if (!Math.isFinite(n) || Math.abs(n) > 1000000) throw "Number outside limit"; return n;
 }
 static function numbers(raw:String):Array<Float> {
  var parts = ~/[,\s]+/g.split(StringTools.trim(raw));
  return [for (part in parts) number(part, 0)];
 }
 static function color(raw:Null<String>, previous:Null<Int>):Null<Int> {
  if (raw == null) return previous;
  if (raw == "none") return null;
  var v = raw.toLowerCase();
  var names = ["black"=>0x000000,"white"=>0xffffff,"red"=>0xff0000,"green"=>0x008000,"blue"=>0x0000ff,"gray"=>0x808080,"grey"=>0x808080];
  if (names.exists(v)) return names.get(v);
  if (~/^#[0-9a-f]{6}$/.match(v)) return Std.parseInt("0x" + v.substr(1));
  if (~/^#[0-9a-f]{3}$/.match(v)) return Std.parseInt("0x" + v.charAt(1)+v.charAt(1)+v.charAt(2)+v.charAt(2)+v.charAt(3)+v.charAt(3));
  throw "Unsupported color";
 }
 static function visit(node:Xml, depth:Int, inheritedFill:Null<Int>, inheritedStroke:Null<Int>, inheritedWidth:Float, shapes:Array<SvgShape>):Void {
  if (++nodes > MAX_NODES || depth > 16) throw "SVG complexity limit";
  var tag = node.nodeName;
  if (tag == "svg" && depth != 0) throw "Nested SVG is unsupported";
  var allowed = switch tag {
   case "svg": ["xmlns","viewBox","width","height","fill","stroke","stroke-width"];
   case "g": ["fill","stroke","stroke-width"];
   case "rect": ["x","y","width","height","fill","stroke","stroke-width"];
   case "circle": ["cx","cy","r","fill","stroke","stroke-width"];
   case "line": ["x1","y1","x2","y2","fill","stroke","stroke-width"];
   case "path": ["d","fill","stroke","stroke-width"];
   default: throw "Unsupported SVG element";
  };
  for (attribute in node.attributes()) if (allowed.indexOf(attribute) < 0) throw "Unsupported SVG attribute";
  if (tag == "svg" && node.get("xmlns") != null && node.get("xmlns") != "http://www.w3.org/2000/svg") throw "Unsupported namespace";
  var fill = color(node.get("fill"), inheritedFill), stroke = color(node.get("stroke"), inheritedStroke);
  var sw = number(node.get("stroke-width"), inheritedWidth); if (sw < 0 || sw > 10000) throw "Invalid stroke width";
  var out:Array<SvgCommand> = [];
  function add(op:String, values:Array<Float>):Void {
   if (++commands > MAX_COMMANDS) throw "SVG path limit";
   for (value in values) if (!Math.isFinite(value) || Math.abs(value) > 1000000) throw "SVG coordinate outside limit";
   out.push({op:op,values:values});
  }
  if (tag == "rect") {
   var x=number(node.get("x"),0), y=number(node.get("y"),0), w=number(node.get("width"),-1), h=number(node.get("height"),-1);
   if (w <= 0 || h <= 0) throw "Invalid rectangle";
   add("M",[x,y]);add("L",[x+w,y]);add("L",[x+w,y+h]);add("L",[x,y+h]);add("Z",[]);
  } else if (tag == "line") {
   add("M",[number(node.get("x1"),0),number(node.get("y1"),0)]); add("L",[number(node.get("x2"),0),number(node.get("y2"),0)]);
  } else if (tag == "circle") {
   var x=number(node.get("cx"),0), y=number(node.get("cy"),0), r=number(node.get("r"),-1), k=0.5522847498;
   if (r <= 0) throw "Invalid circle";
   add("M",[x+r,y]);add("C",[x+r,y+k*r,x+k*r,y+r,x,y+r]);add("C",[x-k*r,y+r,x-r,y+k*r,x-r,y]);
   add("C",[x-r,y-k*r,x-k*r,y-r,x,y-r]);add("C",[x+k*r,y-r,x+r,y-k*r,x+r,y]);add("Z",[]);
  } else if (tag == "path") {
   var d=node.get("d"); if (d == null) throw "Missing path";
   for (cmd in path(d)) add(cmd.op,cmd.values);
  }
  if (out.length > 0) shapes.push({commands:out,fill:fill,stroke:stroke,strokeWidth:sw});
  for (child in node) {
   if (child.nodeType == Xml.Element) {
    if (tag != "svg" && tag != "g") throw "Unexpected child";
    visit(child, depth+1, fill, stroke, sw, shapes);
   } else if (child.nodeType == Xml.PCData && StringTools.trim(child.nodeValue) != "") throw "Unsupported text";
   else if (child.nodeType != Xml.PCData && child.nodeType != Xml.Comment) throw "Unsupported node";
  }
 }
 static function path(raw:String):Array<SvgCommand> {
  var tokens:Array<String> = [], re = ~/[A-Za-z]|[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?/g, pos=0;
  while (re.matchSub(raw,pos)) {
   var m=re.matchedPos(), gap=raw.substring(pos,m.pos);
   if (!~/^[,\s]*$/.match(gap)) throw "Invalid path";
   tokens.push(re.matched(0)); if (tokens.length > MAX_COMMANDS * 7) throw "Path too large"; pos=m.pos+m.len;
  }
  if (!~/^[,\s]*$/.match(raw.substr(pos))) throw "Invalid path";
  var out:Array<SvgCommand> = [], i=0, op="", x=0.0, y=0.0, startX=0.0, startY=0.0;
  while (i < tokens.length) {
   if (~/^[A-Za-z]$/.match(tokens[i])) op=tokens[i++];
   if (op == "") throw "Missing path command";
   var upper=op.toUpperCase(), relative=op != upper;
   if (upper == "Z") {out.push({op:"Z",values:[]}); x=startX;y=startY;op="";continue;}
   var count = switch upper {case "M", "L":2; case "H", "V":1; case "Q":4; case "C":6; default:throw "Unsupported path command";};
   if (i + count > tokens.length) throw "Incomplete path";
   var v:Array<Float>=[]; for (_ in 0...count) v.push(number(tokens[i++],0));
   if (upper == "H") { x = relative ? x+v[0] : v[0]; out.push({op:"L",values:[x,y]}); }
   else if (upper == "V") { y = relative ? y+v[0] : v[0]; out.push({op:"L",values:[x,y]}); }
   else {
    if (relative) for (j in 0...Std.int(count/2)) {v[j*2]+=x;v[j*2+1]+=y;}
    x=v[count-2];y=v[count-1];out.push({op:upper,values:v});
    if (upper == "M") {startX=x;startY=y;op=relative ? "l" : "L";}
   }
   if (out.length > MAX_COMMANDS) throw "Path too large";
  }
  if (out.length == 0 || out[0].op != "M") throw "Path must start with move";
  return out;
 }
}
