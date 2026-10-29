package workspace.provider;

/** Retries identical atomic journal publication after short Windows sharing conflicts. */
class AgentJournalPublisher {
 public static function write(path:String,content:String,windows:Bool, publish:(String,String)->Void, pause:Float->Void):Void {
  var delays = windows ? [0.01,0.02,0.04] : [];
  for (attempt in 0...delays.length + 1) {
   try { publish(path,content); return; }
   catch (error:Dynamic) {
    if (attempt == delays.length) throw error;
    pause(delays[attempt]);
   }
  }
 }
}
