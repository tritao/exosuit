package workspace.client;

import haxeon.rpc.RpcConnection;

/**
  How many bytes of terminal replies (replay batches, snapshot pages) one connection may have asked for and not yet
  received, across all its views. A NativeKit connection closes when more than its 1 MiB receive buffer waits unread, and
  a relay channel queues at most 1 MiB; 384 KiB leaves room for the other services on the same connection.

  A request that finds the budget used up waits and asks again on its next poll. When nothing is in flight a request
  always gets through, so one larger than the budget cannot wait forever. Releases come from reply and error callbacks;
  if a connection is lost without either, the count is dropped after STALE_SECONDS without any activity. Entries of
  closed connections are dropped on the next `reserve`.
**/
class TerminalReplyBudget {
  public static inline final LIMIT = 384 * 1024;
  static inline final STALE_SECONDS = 15.0;
  static final entries:Array<{connection:RpcConnection, used:Int, touched:Float}> = [];

  static function entry(c:RpcConnection):{connection:RpcConnection, used:Int, touched:Float} {
    for (e in entries) if (e.connection == c) return e;
    var made = {connection: c, used: 0, touched: Sys.time()};
    entries.push(made);
    return made;
  }
  /** Takes `bytes` of the connection's budget if they fit; the caller gives them back with `release`. */
  public static function reserve(c:RpcConnection, bytes:Int):Bool {
    var now = Sys.time();
    // Other connections that closed with nothing in flight (or no activity for a while) are dropped from the list.
    var i = entries.length;
    while (i-- > 0) {
      var o = entries[i];
      if (o.connection != c && !o.connection.isOpen() && (o.used == 0 || now - o.touched > STALE_SECONDS)) entries.splice(i, 1);
    }
    var e = entry(c);
    if (e.used > 0 && now - e.touched > STALE_SECONDS) e.used = 0;
    if (e.used > 0 && e.used + bytes > LIMIT) return false;
    e.used += bytes;
    e.touched = now;
    return true;
  }
  public static function release(c:RpcConnection, bytes:Int):Void {
    var e = entry(c);
    e.used -= bytes;
    if (e.used <= 0) {
      e.used = 0;
      // This connection's entry goes once it is closed and has nothing in flight.
      if (!c.isOpen()) entries.remove(e);
    }
    e.touched = Sys.time();
  }
}
