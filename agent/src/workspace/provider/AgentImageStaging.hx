package workspace.provider;

import haxe.io.Bytes;
import haxe.io.BytesBuffer;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;
import workspace.service.WorkspaceAgentProtocol.AgentImageUpload;
import workspace.service.WorkspaceAgentProtocol.AgentImageUploadResult;

private typedef StagedImage = {
  var session:String; var id:String; var size:Int; var offset:Int; var bytes:BytesBuffer;
  var path:Null<String>; var updated:Float; var pinned:Bool; var removed:Bool; var thread:Null<String>;
  var turn:Null<String>; var item:Null<String>;
}

/** Ephemeral, bounded image staging on the provider host. IDs never expose local paths. */
class AgentImageStaging {
  public static inline final MAX_IMAGE = 2 * 1024 * 1024;
  public static inline final MAX_CHUNK = 32 * 1024;
  static inline final MAX_TOTAL = 8 * 1024 * 1024;
  static inline final TTL = 600.0;
  final entries:Map<String,StagedImage> = [];
  final directory:Null<String>;
  final random:Void->String;
  final clock:Void->Float;
  final secureFile:String->Bool;
  final unlock:Void->Void;
  var failed:Bool = false;
  public function new(base:Null<String>, workspaceRoot:String, random:Void->String, clock:Void->Float, secureDir:String->Bool,
      secureFile:String->Bool, lock:String->Bool, unlock:Void->Void) {
    this.random = random; this.clock = clock; this.secureFile = secureFile; this.unlock = unlock;
    var dir:Null<String> = null;
    if (base != null && FileSystem.exists(base) && FileSystem.isDirectory(base)) try {
      var candidate = Path.join([base, "exosuit-agent-images-" + haxe.crypto.Sha256.encode(workspaceRoot)]);
      if (secureDir(candidate) && lock(Path.join([candidate,"leases.lock"]))) dir = candidate;
    } catch (_:Dynamic) {}
    directory = dir;
    if (directory != null) try load() catch (_:Dynamic) failed = true;
  }
  public function available():Bool return directory != null && !failed;
  public function supported():Bool return directory != null;
  function manifestPath():String return Path.join([directory, "leases.json"]);
  function persist():Void {
    if (directory == null || failed) throw "Image lease storage requires recovery";
    var records:Array<Dynamic> = [];
    for (item in entries) if (item.path != null) records.push({id:item.id,session:item.session,size:item.size,
      ext:item.path.substr(item.path.lastIndexOf(".") + 1),updated:item.updated,pinned:item.pinned,removed:item.removed,thread:item.thread,turn:item.turn,item:item.item});
    var path = manifestPath();
    var content=haxe.Json.stringify({version:1, entries:records});
    AgentJournalPublisher.write(path,content,Sys.systemName()=="Windows",sys.io.AtomicFile.write,Sys.sleep);
    if (!secureFile(path)) throw "Image lease journal is not private";
  }
  function load():Void {
    var path = manifestPath();
    if (!FileSystem.exists(path)) return;
    if (!secureFile(path)) throw "Image lease journal is not private";
    var journalMetadata = FileSystem.metadata(path);
    if (journalMetadata == null || journalMetadata.size < 0 || journalMetadata.size > 65536) throw "Image lease journal is too large";
    var data:Dynamic = haxe.Json.parse(File.getContent(path));
    var records:Dynamic = Reflect.field(data,"entries");
    if (Reflect.field(data,"version") != 1 || !Std.isOfType(records,Array) || (cast records:Array<Dynamic>).length > 40) throw "Invalid image lease journal";
    var total = 0, dirty = false;
    for (record in (cast records:Array<Dynamic>)) {
      var id:Dynamic = Reflect.field(record,"id"), session:Dynamic = Reflect.field(record,"session"), ext:Dynamic = Reflect.field(record,"ext");
      var size:Dynamic = Reflect.field(record,"size"), updated:Dynamic = Reflect.field(record,"updated"), thread:Dynamic = Reflect.field(record,"thread");
      var turn:Dynamic=Reflect.field(record,"turn"), itemId:Dynamic=Reflect.field(record,"item");
      if (!Std.isOfType(id,String) || id.length < 24 || id.length > 256 || !~/^[A-Za-z0-9_-]+$/.match(id)
        || !Std.isOfType(session,String) || session.length == 0 || session.length > 128
        || !Std.isOfType(size,Int) || size <= 0 || size > MAX_IMAGE || ["png","jpg","gif"].indexOf(ext) < 0
        || !Std.isOfType(updated,Float) && !Std.isOfType(updated,Int) || !Math.isFinite(updated)
        || (thread != null && (!Std.isOfType(thread,String) || thread.length > 1024))
        || ((turn == null) != (itemId == null)) || (turn != null && (!Std.isOfType(turn,String) || turn.length == 0 || turn.length > 128
          || !Std.isOfType(itemId,String) || itemId.length == 0 || itemId.length > 128)) || entries.exists(id)) throw "Invalid image lease";
      var file = Path.join([directory, id + "." + ext]);
      var pinned = Reflect.field(record,"pinned") == true;
      if (!FileSystem.exists(file)) {
        if (!pinned) { dirty = true; continue; }
      } else {
        var metadata = FileSystem.metadata(file);
        if (!secureFile(file) || metadata == null) throw "Staged image is unavailable";
        if (metadata.size != size) {
          if (pinned) throw "Staged image is unavailable";
          FileSystem.deleteFile(file); dirty = true; continue;
        }
      }
      total += size; if (total > 72 * 1024 * 1024) throw "Image lease quota exceeded";
      entries.set(id,{session:session,id:id,size:size,offset:size,bytes:new BytesBuffer(),path:file,updated:updated,
        pinned:pinned, removed:Reflect.field(record,"removed") == true,thread:thread,turn:turn,item:itemId});
    }
    if (dirty) persist();
  }
  public function process(q:AgentImageUpload):AgentImageUploadResult {
    clean(function(_) return true, function(_, _) return true);
    if (!available()) throw "Image staging requires recovery; check the workspace service";
    if (q.session == null || q.session == "" || q.session.length > 128) throw "Invalid session";
    if (q.operation == "begin") {
      if (q.size <= 0 || q.size > MAX_IMAGE) throw "Image must be at most 2 MiB";
      var ready = 0, partial = 0, total = 0, count = 0;
      for (item in entries) {
        if (item.turn == null) {
          total += item.size; count++;
          if (item.session == q.session && !item.removed) { if (item.path == null) partial++; else ready++; }
        }
      }
      if (ready >= 2 || partial >= 4 || count >= 8 || total + q.size > MAX_TOTAL) throw "Image staging quota reached; wait for abandoned uploads to expire or reconcile the session";
      var id = random();
      if (id == null || id.length < 24 || !~/^[A-Za-z0-9_-]+$/.match(id) || entries.exists(id)) throw "Could not create image identity";
      entries.set(id,{session:q.session,id:id,size:q.size,offset:0,bytes:new BytesBuffer(),path:null,updated:clock(),pinned:false,removed:false,thread:null,turn:null,item:null});
      return {upload:id,offset:0,complete:false};
    }
    var entry = q.upload == null ? null : entries.get(q.upload);
    if (entry == null || entry.session != q.session || entry.removed) throw "Image upload expired or is unavailable";
    entry.updated = clock();
    if (q.operation == "remove") {
      entry.removed = true; if (!entry.pinned && entry.turn == null) discard(entry); else persist();
      return {upload:entry.id,offset:entry.offset,complete:entry.path != null};
    }
    if (q.operation == "chunk") {
      var chunk:Null<Bytes> = q.bytes;
      if (entry.path != null || chunk == null || chunk.length == 0 || chunk.length > MAX_CHUNK
        || q.offset != entry.offset || chunk.length > entry.size - entry.offset) throw "Invalid image upload chunk";
      var data:Bytes = cast chunk;
      entry.bytes.add(data); entry.offset += data.length;
      return {upload:entry.id,offset:entry.offset,complete:false};
    }
    if (q.operation != "finish" || entry.path != null || entry.offset != entry.size) throw "Image upload is incomplete";
    var data = entry.bytes.getBytes(), extension = imageExtension(data);
    if (extension == null) { discard(entry); throw "Choose a valid PNG, JPEG, or GIF image up to 4096 pixels per side"; }
    var path = Path.join([directory, entry.id + "." + extension]);
    try {
      // Journal the intended file first. A crash between publication steps
      // fails closed on recovery instead of leaving unaccounted image bytes.
      entry.path = path;
      persist();
      if (FileSystem.exists(path)) throw "Image identity already exists";
      // The private directory and journal own this exact path. Writing it
      // directly avoids an untracked image-bearing atomic temporary file.
      File.saveBytes(path,data);
      if (!secureFile(path)) throw "Could not protect staged image";
      entry.bytes = new BytesBuffer();
    } catch (_:Dynamic) { try if (FileSystem.exists(path)) FileSystem.deleteFile(path) catch (_:Dynamic) {} discard(entry); throw "Could not stage image"; }
    return {upload:entry.id,offset:entry.offset,complete:true};
  }
  public function resolve(session:String, ids:Array<String>):Null<Array<String>> {
    if (ids == null || ids.length == 0 || ids.length > 2) return null;
    var result:Array<String> = [], seen:Map<String,Bool> = [];
    for (id in ids) {
      if (id == null || id.length < 24 || id.length > 256 || !~/^[A-Za-z0-9_-]+$/.match(id)) return null;
      var item = entries.get(id);
      if (item == null || item.session != session || item.path == null || item.removed || seen.exists(id)
        || clock() - item.updated > TTL || !FileSystem.exists(item.path)) return null;
      seen.set(id,true); result.push(item.path);
    }
    return result;
  }
  public function pin(session:String, thread:String, ids:Array<String>):Bool {
    if (resolve(session, ids) == null) return false;
    for (id in ids) { var item = entries.get(id); item.pinned = true; item.thread = thread; item.updated = clock(); }
    try persist() catch (_:Dynamic) { failed = true; return false; }
    return true;
  }
  /** Associate only a path that this service itself staged for this active session. */
  public function archive(session:String,turn:String,itemId:String,path:String):Null<String> {
    if (!available() || turn == null || turn == "" || turn.length > 128 || itemId == null || itemId == "" || itemId.length > 128 || path == null) return null;
    var candidate:Null<StagedImage>=null;
    for (entry in entries) if (entry.session == session && entry.path == path) candidate=entry;
    if (candidate == null || candidate.path == null || !FileSystem.exists(candidate.path)) return null;
    if (candidate.turn != null) return candidate.turn == turn && candidate.item == itemId ? candidate.id : null;
    if (!candidate.pinned) return null;
    var archived:Array<StagedImage>=[for (entry in entries) if (entry.turn != null) entry];
    var total=0; for (entry in archived) total+=entry.size;
    archived.sort(function(a,b) return Reflect.compare(a.updated,b.updated));
    while (archived.length >= 32 || total + candidate.size > 64 * 1024 * 1024) {
      var victim:Null<StagedImage>=null;
      for (entry in archived) if (!entry.pinned && victim == null) victim=entry;
      if (victim == null) return null;
      var before=entries.exists(victim.id); discard(victim);
      if (before && entries.exists(victim.id)) return null;
      archived.remove(victim); total-=victim.size;
    }
    candidate.turn=turn; candidate.item=itemId; candidate.updated=clock();
    try persist() catch (_:Dynamic) {candidate.turn=null; candidate.item=null; failed=true; return null;}
    return candidate.id;
  }
  public function readArchive(session:String,turn:String,itemId:String,id:String,offset:Int):Null<workspace.service.WorkspaceAgentProtocol.AgentContentChunk> {
    if (!available() || id == null || offset < 0) return null;
    var entry=entries.get(id);
    if (entry == null || entry.session != session || entry.turn != turn || entry.item != itemId || entry.path == null) return null;
    try {
      var metadata=FileSystem.metadata(entry.path);
      if (metadata == null || metadata.size != entry.size || !secureFile(entry.path)) return null;
      var bytes=File.getBytes(entry.path);
      // Validate the complete encoded image at the start of a read. Repeating
      // PNG CRC validation for every 24 KiB slice makes large images quadratic.
      if (bytes.length != entry.size || (offset == 0 && imageExtension(bytes) == null) || offset >= bytes.length) return null;
      var length=Std.int(Math.min(24*1024,bytes.length-offset));
      return {token:id,offset:offset,total:bytes.length,bytes:bytes.sub(offset,length),partial:false};
    } catch (_:Dynamic) return null;
  }
  public function clean(exists:String->Bool, active:(String, Null<String>)->Bool):Void {
    var now = clock();
    for (item in [for (v in entries) v]) {
      if (item.pinned && !active(item.session, item.thread)) {
        item.pinned = false;
        try persist() catch (_:Dynamic) { item.pinned = true; failed = true; }
      }
      if (!item.pinned && (!exists(item.session) || (item.turn == null && (item.removed || now - item.updated > TTL)))) discard(item);
    }
  }
  function discard(item:StagedImage):Void {
    if (item.path != null) {
      try if (FileSystem.exists(item.path)) FileSystem.deleteFile(item.path) catch (_:Dynamic) { return; }
    }
    entries.remove(item.id);
    if (item.path != null) try persist() catch (_:Dynamic) { entries.set(item.id,item); failed = true; }
  }
  public function dispose():Void {
    for (item in [for (v in entries) v]) if (!item.pinned && item.turn == null) discard(item);
    if (directory != null) unlock();
  }
  static function be32(b:Bytes,p:Int):Int return (b.get(p)<<24)|(b.get(p+1)<<16)|(b.get(p+2)<<8)|b.get(p+3);
  static function crc32(bytes:Bytes, offset:Int, length:Int):Int {
    var crc = -1;
    for (index in offset...offset+length) {
      var value = (crc ^ bytes.get(index)) & 255;
      for (_ in 0...8) value = (value >>> 1) ^ (-(value & 1) & 0xedb88320);
      crc = (crc >>> 8) ^ value;
    }
    return crc ^ -1;
  }
  public static function imageExtension(bytes:Bytes):Null<String> {
    if (bytes == null || bytes.length < 10 || bytes.length > MAX_IMAGE) return null;
    var w = 0, h = 0, ext:Null<String> = null;
    if (bytes.length >= 24 && bytes.get(0)==137 && bytes.get(1)==80 && bytes.get(2)==78 && bytes.get(3)==71
      && bytes.get(4)==13 && bytes.get(5)==10 && bytes.get(6)==26 && bytes.get(7)==10 && bytes.getString(12,4)=="IHDR") {
      w=be32(bytes,16);h=be32(bytes,20);
      var p=8, hasHeader=false, hasData=false, hasEnd=false;
      while (p + 12 <= bytes.length) {
        var length=be32(bytes,p);
        if (length < 0 || length > bytes.length - p - 12) return null;
        var kind=bytes.getString(p+4,4);
        if (crc32(bytes,p+4,length+4)!=be32(bytes,p+8+length)) return null;
        if (!hasHeader) { if (kind!="IHDR" || length!=13) return null; hasHeader=true; }
        else if (kind=="IHDR") return null;
        if (kind=="IDAT") hasData=true;
        if (kind=="IEND") { if (length!=0 || p+12!=bytes.length) return null; hasEnd=true; break; }
        p+=length+12;
      }
      if (!hasHeader || !hasData || !hasEnd) return null;
      ext="png";
    } else if (bytes.getString(0,6)=="GIF87a" || bytes.getString(0,6)=="GIF89a") {
      if (bytes.length < 14 || bytes.get(bytes.length-1)!=0x3b) return null;
      w=bytes.get(6)|(bytes.get(7)<<8);h=bytes.get(8)|(bytes.get(9)<<8);ext="gif";
    } else if (bytes.get(0)==255 && bytes.get(1)==216) {
      if (bytes.length < 4 || bytes.get(bytes.length-2)!=255 || bytes.get(bytes.length-1)!=217) return null;
      var p=2;
      while (p+3<bytes.length) {
        if (bytes.get(p++)!=255) return null;
        while (p<bytes.length && bytes.get(p)==255) p++;
        if (p>=bytes.length) return null;
        var marker=bytes.get(p++);
        if (marker==217 || marker==218) break;
        if (marker==1 || marker>=208 && marker<=215) continue;
        if (p+1>=bytes.length) return null;
        var len=(bytes.get(p)<<8)|bytes.get(p+1);
        if (len<2 || p+len>bytes.length) return null;
        if ((marker>=192 && marker<=195)||(marker>=197 && marker<=199)||(marker>=201 && marker<=203)||(marker>=205 && marker<=207)) {
          if (len<7) return null;h=(bytes.get(p+3)<<8)|bytes.get(p+4);w=(bytes.get(p+5)<<8)|bytes.get(p+6);ext="jpg";break;
        }
        p+=len;
      }
    }
    return w>0 && h>0 && w<=4096 && h<=4096 ? ext : null;
  }
}
