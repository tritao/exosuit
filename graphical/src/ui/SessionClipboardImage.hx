package ui;

import haxe.io.Bytes;

/** Reads an image without changing the system clipboard. */
class SessionClipboardImage {
  public static function read():{bytes:Null<Bytes>, error:Null<String>} {
    var buffer = Bytes.alloc(2 * 1024 * 1024);
    var count = clipboardImage(ClipboardBytes.data(buffer), buffer.length);
    if (count == 0) return {bytes:null, error:null};
    if (count < 0) return {bytes:null, error:count == -1 ? "Clipboard image exceeds the supported size" : "Could not read clipboard image"};
    return {bytes:buffer.sub(0, count), error:null};
  }
}

@:cNative("exosuit_clipboard", "exosuit_clipboard_image", "11,5>5")
extern function clipboardImage(output:hl.Bytes, capacity:Int):Int;
private extern class ClipboardBytes {
  @:hlNative("haxeon_runtime", "__bytes_get_data") public static function data(value:Bytes):hl.Bytes;
}
