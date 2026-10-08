package workspace.service;

import haxe.Int64;
import haxe.io.Bytes;
import workspace.service.WorkspaceTerminalProtocol.TerminalReplayEvent;

/** Bounded, immutable output/geometry journal in the daemon emulator's application order. */
class TerminalReplayLog {
  public var startOffset(default, null):Int64 = 0;
  public var endOffset(default, null):Int64 = 0;
  public var startCursor(default, null):Int64 = 0;
  public var endCursor(default, null):Int64 = 0;
  final limit:Int;
  final entries:Array<TerminalReplayEvent> = [];
  var retained:Int = 0;

  public function new(columns:Int, rows:Int, limit:Int) {
    if (limit < 65536) throw "Terminal replay limit is too small";
    this.limit = limit;
    geometry(columns, rows);
  }
  public function geometry(columns:Int, rows:Int):Void {
    append(Bytes.alloc(0), columns, rows);
  }
  /** Native PTY memory is borrowed. Own each bounded record before returning. */
  public function output(bytes:Bytes, length:Int):Void {
    if (bytes == null || length < 0 || length > bytes.length) throw "Invalid terminal output";
    var consumed = 0;
    while (consumed < length) {
      var take = Std.int(Math.min(65536, length - consumed));
      append(bytes.sub(consumed, take), 0, 0);
      consumed += take;
    }
  }
  function append(data:Bytes, columns:Int, rows:Int):Void {
    entries.push({sequence:endCursor, offset:endOffset, data:data, columns:columns, rows:rows});
    endCursor += 1;
    endOffset += data.length;
    retained += data.length + 64;
    // Bound metadata too: repeated resizes without output must not grow forever.
    while (entries.length > 1 && (retained > limit || entries.length > 4096)) {
      var old = entries.shift();
      retained -= old.data.length + 64;
      startOffset = old.offset + old.data.length;
      startCursor = old.sequence + 1;
    }
  }
  public function read(cursor:Int64):{events:Array<TerminalReplayEvent>, next:Int64} {
    if (cursor < startCursor || cursor > endCursor) throw "Invalid terminal replay cursor";
    var result:Array<TerminalReplayEvent> = [], size = 0, next = cursor;
    for (entry in entries) {
      if (entry.sequence < cursor) continue;
      if (result.length >= 128 || (result.length > 0 && size + entry.data.length > 65536)) break;
      result.push(entry);
      size += entry.data.length;
      next = entry.sequence + 1;
    }
    return {events:result, next:next};
  }
  /** Compatibility for byte-only readers. New clients use read(). */
  public function readBytes(offset:Int64):Bytes {
    if (offset < startOffset || offset > endOffset) throw "Invalid terminal output offset";
    var length = Int64.toInt(endOffset - offset > 65536 ? Int64.ofInt(65536) : endOffset - offset);
    var bytes = Bytes.alloc(length), copied = 0;
    for (entry in entries) {
      if (copied == length) break;
      if (entry.offset + entry.data.length <= offset) continue;
      var skip = offset > entry.offset ? Int64.toInt(offset - entry.offset) : 0;
      var take = Std.int(Math.min(entry.data.length - skip, length - copied));
      bytes.blit(copied, entry.data, skip, take);
      copied += take;
    }
    return bytes;
  }
}
