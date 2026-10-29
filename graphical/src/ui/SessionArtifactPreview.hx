package ui;

import haxe.io.Bytes;

/** Opens the platform's isolated static artifact surface. */
class SessionArtifactPreview {
  public static function available():Bool return artifactPreviewAvailable() != 0;
  public static function open(window:Int, source:String):Bool {
    var bytes = Bytes.ofString(source);
    if (bytes.length == 0 || bytes.length > 512 * 1024) return false;
    for (index in 0...bytes.length) if (bytes.get(index) == 0) return false;
    var terminated = Bytes.alloc(bytes.length + 1);
    terminated.blit(0, bytes, 0, bytes.length);
    return artifactPreview(window, ArtifactBytes.data(terminated)) != 0;
  }
}

@:cNative("exosuit_artifact_preview", "exosuit_artifact_preview_open", "5,11>5")
extern function artifactPreview(window:Int, source:hl.Bytes):Int;
@:cNative("exosuit_artifact_preview", "exosuit_artifact_preview_available", ">5")
extern function artifactPreviewAvailable():Int;
private extern class ArtifactBytes {
  @:hlNative("haxeon_runtime", "__bytes_get_data") public static function data(value:Bytes):hl.Bytes;
}
