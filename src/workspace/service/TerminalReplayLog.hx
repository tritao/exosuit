package workspace.service;

import haxe.Int64;
import haxe.io.Bytes;
import workspace.service.WorkspaceTerminalProtocol.TerminalReplayEvent;

/** Bounded, immutable output/geometry journal in the daemon emulator's application order. */
class TerminalReplayLog {
  /**
    One journal record and one REPLAY answer stay well under a relay frame (the machine stream's payload is at most 65487
    bytes, and the answer carries the terminal's info and per-event fields besides the bytes). A burst is cut into
    records of at most `CHUNK_BYTES`; an answer holds at most `BATCH_BYTES` of output.
  **/
  public static inline final CHUNK_BYTES = 24576;
  public static inline final BATCH_BYTES = 49152;
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
      var take = Std.int(Math.min(CHUNK_BYTES, length - consumed));
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
  /**
    Forgets every record, keeping the counters: a reader behind this point gets a replay gap and takes a snapshot. For
    content that reached the emulator outside this journal (a screen restored from a terminal host).
  **/
  public function cut():Void {
    entries.resize(0);
    retained = 0;
    startOffset = endOffset;
    startCursor = endCursor;
  }
  /**
    Forgets every record and continues numbering at `cursor` and `offset` when they are ahead: for a journal rebuilt from
    saved history, so a view that read the earlier journal of the same terminal is not ahead of it (and is not refused).
  **/
  public function continueFrom(cursor:Int64, offset:Int64):Void {
    cut();
    if (cursor > endCursor) { startCursor = cursor; endCursor = cursor; }
    if (offset > endOffset) { startOffset = offset; endOffset = offset; }
  }
  public function read(cursor:Int64):{events:Array<TerminalReplayEvent>, next:Int64} {
    if (cursor < startCursor || cursor > endCursor) throw "Invalid terminal replay cursor";
    var result:Array<TerminalReplayEvent> = [], size = 0, next = cursor;
    for (entry in entries) {
      if (entry.sequence < cursor) continue;
      if (result.length >= 128 || (result.length > 0 && size + entry.data.length > BATCH_BYTES)) break;
      result.push(entry);
      size += entry.data.length;
      next = entry.sequence + 1;
    }
    return {events:result, next:next};
  }
}
