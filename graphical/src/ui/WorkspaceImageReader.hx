package ui;

import haxe.Int64;
import haxe.io.Bytes;
import haxe.io.BytesBuffer;
import workspace.client.WorkspaceFileClient;

/** Reads a revision-pinned remote raster without exposing a host path to local I/O. */
class WorkspaceImageReader {
  public static inline final CHUNK = 32 * 1024;
  public static function read(client:WorkspaceFileClient, workspace:String, root:String, path:String,
      done:(Null<Bytes>, Null<String>)->Void, ?wanted:Void->Bool):Void {
    var finished = false;
    function current():Bool return wanted == null || wanted();
    function finish(bytes:Null<Bytes>, error:Null<String>):Void {
      if (finished) return;
      finished = true;
      if (!current()) done(null, "Session changed while reading the image"); else done(bytes, error);
    }
    if (client == null || !current()) { finish(null, "Workspace file service is unavailable"); return; }
    client.stat(workspace, root, path, function(stat) {
      if (!current()) { finish(null, "Session changed while reading the image"); return; }
      if (stat == null || stat.workspace != workspace || stat.root != root || stat.path != path || stat.entry == null
          || stat.entry.kind != "file" || stat.entry.revision == null || stat.entry.revision == "" || stat.entry.size == null
          || Int64.compare(stat.entry.size, Int64.ofInt(0)) <= 0
          || Int64.compare(stat.entry.size, Int64.ofInt(SessionImageProbe.MAX_BYTES)) > 0) {
        finish(null, "Choose an image of at most 4 MiB"); return;
      }
      var revision = stat.entry.revision, size = Int64.toInt(stat.entry.size);
      client.openRead(workspace, root, path, revision, function(opened) {
        if (finished) return;
        if (opened == null || opened.workspace != workspace || opened.root != root || opened.path != path
            || opened.handle == null || opened.handle == "" || opened.revision != revision || opened.size == null
            || Int64.compare(opened.size, Int64.ofInt(size)) != 0) {
          if (opened != null && opened.handle != null && opened.handle != "") client.closeRead(workspace, opened.handle, function(_) {}, function(_) {});
          finish(null, "Image changed or returned invalid file metadata"); return;
        }
        var handle = opened.handle, buffer = new BytesBuffer(), closed = false;
        function close():Void { if (!closed) { closed = true; client.closeRead(workspace, handle, function(_) {}, function(_) {}); } }
        function fail(message:String):Void { close(); finish(null, message); }
        if (!current()) { fail("Session changed while reading the image"); return; }
        var next:Int->Void = null;
        next = function(offset:Int) {
          if (finished) return;
          if (!current()) { fail("Session changed while reading the image"); return; }
          if (offset == size) {
            close(); var bytes = buffer.getBytes();
            if (SessionImageProbe.dimensions(bytes) == null) finish(null, "Unsupported image or dimensions exceed 4096 pixels");
            else finish(bytes, null);
            return;
          }
          var count = Std.int(Math.min(CHUNK, size - offset));
          client.readChunk(workspace, handle, Int64.ofInt(offset), count, function(chunk) {
            if (!current()) { fail("Session changed while reading the image"); return; }
            if (chunk == null || chunk.handle != handle || chunk.revision != revision || chunk.offset == null
                || Int64.compare(chunk.offset, Int64.ofInt(offset)) != 0 || chunk.bytes == null || chunk.bytes.length != count
                || chunk.eof != (offset + count == size)) { fail("Image changed or returned an invalid read chunk"); return; }
            buffer.addBytes(chunk.bytes, 0, count); next(offset + count);
          }, function(error) fail(error == null ? "Could not read workspace image" : error.message));
        };
        if (opened.initialBytes != null) {
          if (opened.initialBytes.length != size || size > CHUNK) { fail("Workspace returned invalid image bytes"); return; }
          buffer.addBytes(opened.initialBytes, 0, size); next(size);
        } else next(0);
      }, function(error) finish(null, error == null ? "Could not open workspace image" : error.message), 5000, CHUNK);
    }, function(error) finish(null, error == null ? "Could not inspect workspace image" : error.message));
  }
}
