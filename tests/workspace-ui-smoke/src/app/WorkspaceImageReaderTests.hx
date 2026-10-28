package app;

import haxe.Int64;
import haxe.io.Bytes;
import haxeon.rpc.MemoryTransport;
import haxeon.rpc.RpcConnection;
import workspace.client.WorkspaceFileClient;
import workspace.service.WorkspaceFileProtocol;
import ui.WorkspaceImageReader;

/** Exercises bounded binary reads through the actual RPC encoding. */
class WorkspaceImageReaderTests {
  static function check(value:Bool, message:String):Void { if (!value) throw message; }
  public static function run():Void {
    var pair = MemoryTransport.pair();
    var client = new RpcConnection(pair.client, Sys.time), server = new RpcConnection(pair.server, Sys.time);
    var files = new WorkspaceFileClient(client), bytes = Bytes.alloc(300001);
    var header = [137,80,78,71,13,10,26,10]; for (i in 0...header.length) bytes.set(i, header[i]);
    bytes.blit(12, Bytes.ofString("IHDR"), 0, 4); bytes.set(19, 1); bytes.set(23, 1);
    var mode = "ok", opens = 0, chunks = 0, closes = 0, wanted = true;
    server.register(WorkspaceFileProtocol.STAT, function(q, ctx) {
      var size = mode == "oversize" ? 4 * 1024 * 1024 + 1 : bytes.length;
      var zero = Int64.ofInt(0);
      ctx.respond({workspace:q.workspace,root:q.root,path:q.path,entry:{name:"image.png",kind:"file",size:Int64.ofInt(size),
        modifiedUnixNs:zero,fileIdHigh:zero,fileIdLow:zero,nameUnsupported:false,revision:"r1"}});
    });
    server.register(WorkspaceFileProtocol.READ_OPEN, function(q, ctx) {
      opens++;
      check(q.initialBytesLimit == WorkspaceImageReader.CHUNK, "image inline byte limit is not relay-safe");
      ctx.respond({workspace:q.workspace,root:q.root,path:q.path,handle:"handle",revision:mode == "revision" ? "r2" : "r1",size:Int64.ofInt(bytes.length)});
    });
    server.register(WorkspaceFileProtocol.READ_CHUNK, function(q, ctx) {
      chunks++; var offset = Int64.toInt(q.offset);
      check(q.length > 0 && q.length <= WorkspaceImageReader.CHUNK, "image chunk is not relay-safe");
      if (mode == "cancel") wanted = false;
      ctx.respond({handle:q.handle,revision:mode == "chunk-revision" ? "r2" : "r1",offset:q.offset,
        bytes:bytes.sub(offset,q.length),eof:offset + q.length == bytes.length});
    });
    server.register(WorkspaceFileProtocol.READ_CLOSE, function(_, ctx) { closes++; ctx.respond({closed:true}); });
    function runCase(which:String):{bytes:Null<Bytes>,error:Null<String>} {
      mode = which; wanted = true;
      var result:{bytes:Null<Bytes>,error:Null<String>} = {bytes:null,error:null}, completed = false;
      WorkspaceImageReader.read(files,"workspace","root","image.png",function(value,error) {
        result = {bytes:value,error:error}; completed = true;
      },function() return wanted);
      for (_ in 0...30) { server.poll(); client.poll(); }
      check(completed,"image read did not finish: " + which); return result;
    }
    var good = runCase("ok");
    check(good.error == null && good.bytes != null && good.bytes.length == bytes.length
      && chunks == Std.int(Math.ceil(bytes.length / WorkspaceImageReader.CHUNK)) && closes == 1,
      "bounded multi-chunk image read failed");
    var longPath = StringTools.rpad("", "p", 1024), longHandle = StringTools.rpad("", "h", 256);
    var payload = WorkspaceFileProtocol.READ_CHUNK.encodeResponse({handle:longHandle,revision:longHandle,offset:Int64.ofInt(0),
      bytes:Bytes.alloc(WorkspaceImageReader.CHUNK),eof:false});
    var envelope = haxeon.rpc.RpcProtocol.encode(haxeon.rpc.RpcEnvelope.Response(2147483647,payload), (workspace.transport.RelaySocketLink.MAX_MESSAGE_BYTES - 1 - 16));
    check(envelope.length <= (workspace.transport.RelaySocketLink.MAX_MESSAGE_BYTES - 1 - 16), "image chunk exceeds relay plaintext limit");
    var inlinePayload = WorkspaceFileProtocol.READ_OPEN.encodeResponse({workspace:longHandle,root:"root",path:longPath,handle:longHandle,
      revision:longHandle,size:Int64.ofInt(WorkspaceImageReader.CHUNK),initialBytes:Bytes.alloc(WorkspaceImageReader.CHUNK)});
    var inlineEnvelope = haxeon.rpc.RpcProtocol.encode(haxeon.rpc.RpcEnvelope.Response(2147483647,inlinePayload), (workspace.transport.RelaySocketLink.MAX_MESSAGE_BYTES - 1 - 16));
    check(inlineEnvelope.length <= (workspace.transport.RelaySocketLink.MAX_MESSAGE_BYTES - 1 - 16), "inline image response exceeds relay plaintext limit");
    var before = opens, oversize = runCase("oversize");
    check(oversize.error != null && opens == before, "oversized image was opened");
    var revision = runCase("revision");
    check(revision.error != null && revision.bytes == null && closes == 2, "changed revision was accepted or handle leaked");
    var changed = runCase("chunk-revision");
    check(changed.error != null && changed.bytes == null && closes == 3, "changed chunk revision was accepted or handle leaked");
    var cancelled = runCase("cancel");
    check(cancelled.error != null && cancelled.bytes == null && closes == 4, "stale session read completed or leaked its handle");
    client.close(); server.close();
  }
}
