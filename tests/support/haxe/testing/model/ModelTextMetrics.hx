package testing.model;

/** Deterministic metrics for model tests. No fonts, frames, windows, or native handles. */
class ModelTextMetrics {
 public var lineHeight(default, null):Int;
 public var fontPath(default, null):String;
 public var fontSize(default, null):Int;
 public var fontFallbackPaths(default, null):Array<String>;
 public var revision(default, null):Int = 0;
 public function new(fontPath:String, fontSize:Int, ?fallbackPaths:Array<String>) {
  this.fontPath = fontPath; this.fontSize = fontSize; lineHeight = fontSize;
  fontFallbackPaths = fallbackPaths == null ? [] : fallbackPaths.copy();
 }
 public function textWidth(value:String):Int return value.length * Std.int((fontSize * 3 + 2) / 5);
 public function reloadFont(path:String, size:Int, ?fallbacks:Array<String>):Bool {
  if (size <= 0) return false;
  fontPath = path; fontSize = size; lineHeight = size;
  fontFallbackPaths = fallbacks == null ? [] : fallbacks.copy(); revision++;
  return true;
 }
}
