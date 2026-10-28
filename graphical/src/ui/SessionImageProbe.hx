package ui;

import haxe.io.Bytes;

/** Bounded header probe before asking the native decoder to allocate pixels. */
class SessionImageProbe {
 public static inline final MAX_BYTES = 4 * 1024 * 1024;
 public static inline final MAX_DIMENSION = 4096;
 public static function readBounded(path:String):Null<Bytes> {
  var metadata = sys.FileSystem.metadata(path);
  if (metadata == null || metadata.size <= 0 || metadata.size > MAX_BYTES) return null;
  // Haxeon's file API supplies whole-file reads. Check both before and after
  // reading; the native decoder is never asked to decode oversized input.
  var bytes = sys.io.File.getBytes(path);
  return bytes.length > MAX_BYTES ? null : bytes;
 }
 public static function dimensions(bytes:Bytes):Null<{width:Int, height:Int}> {
  if (bytes == null || bytes.length > MAX_BYTES || bytes.length < 10) return null;
  var w = 0, h = 0;
  if (bytes.length >= 24 && bytes.get(0) == 137 && bytes.get(1) == 80 && bytes.get(2) == 78 && bytes.get(3) == 71
      && bytes.get(4) == 13 && bytes.get(5) == 10 && bytes.get(6) == 26 && bytes.get(7) == 10
      && bytes.getString(12, 4) == "IHDR") {
   w = be32(bytes, 16); h = be32(bytes, 20);
  } else if ((bytes.getString(0, 6) == "GIF87a" || bytes.getString(0, 6) == "GIF89a")) {
   w = bytes.get(6) | (bytes.get(7) << 8); h = bytes.get(8) | (bytes.get(9) << 8);
  } else if (bytes.get(0) == 255 && bytes.get(1) == 216) {
   var p = 2;
   while (p + 3 < bytes.length) {
    if (bytes.get(p++) != 255) return null;
    while (p < bytes.length && bytes.get(p) == 255) p++;
    if (p >= bytes.length) return null;
    var marker = bytes.get(p++);
    if (marker == 217 || marker == 218) break;
    if (marker == 1 || (marker >= 208 && marker <= 215)) continue;
    if (p + 1 >= bytes.length) return null;
    var len = (bytes.get(p) << 8) | bytes.get(p + 1);
    if (len < 2 || p + len > bytes.length) return null;
    if ((marker >= 192 && marker <= 195) || (marker >= 197 && marker <= 199)
       || (marker >= 201 && marker <= 203) || (marker >= 205 && marker <= 207)) {
     if (len < 7) return null;
     h = (bytes.get(p + 3) << 8) | bytes.get(p + 4);
     w = (bytes.get(p + 5) << 8) | bytes.get(p + 6); break;
    }
    p += len;
   }
  }
  return w > 0 && h > 0 && w <= MAX_DIMENSION && h <= MAX_DIMENSION ? {width:w, height:h} : null;
 }
 static function be32(b:Bytes, p:Int):Int
  return (b.get(p) << 24) | (b.get(p + 1) << 16) | (b.get(p + 2) << 8) | b.get(p + 3);
}
