package app;

import workspace.provider.AgentNameSync;
import workspace.provider.AgentMetadata;
import workspace.service.WorkspaceAgentProtocol;

class AgentNameSyncTest {
 static function require(ok:Bool,why:String):Void {if(!ok) throw why;}
 public static function run():Void {
  var nativeName:Null<String>="Native title",writes=0,saves=0,done=false,code="",ambiguous=false;
  var failSaveAt=-1,failRead=false,loseResponse=false;
  var record:AgentRecord={id:"agent",name:"Existing local label",group:"work",cwd:"/tmp",thread:"native-id",state:"disconnected",turn:null,workspaceRoot:"/tmp",provider:"codex"};
  var durable:AgentRecord=cast Reflect.copy(record);
  function metadata():AgentNameMetadata return cast record.nameMetadata;
  function save():Void {
   saves++;if(saves==failSaveAt) throw "storage failure";
   durable=cast Reflect.copy(record);
  }
  function read(callback:workspace.provider.AgentNameSync.NativeNameReadDone):Void {
   if(failRead) callback(null,{code:"disconnected",message:"offline",ambiguous:false});else callback(nativeName,null);
  }
  function write(name:String,expected:Null<String>,callback:Null<haxeon.rpc.RpcError>->Void):Void {
   require(record.nameMetadata!=null && metadata().pending!=null,"native write preceded durable intent");
   require(durable.nameMetadata!=null && durable.nameMetadata.pending!=null,"intent was not durable before native write");
   writes++;nativeName=name;
   callback(loseResponse ? {code:"timeout",message:"response lost",ambiguous:true} : null);
  }
  function success():Void done=true;
  function failure(error:haxeon.rpc.RpcError):Void {code=error.code;ambiguous=error.ambiguous;}
  var sync=new AgentNameSync(record,save,read,write,function() return 0.0);
  sync.inspect(success,failure);
  require(done && writes==0 && record.name=="Existing local label" && record.nameMetadata!=null && metadata().source=="workbench","migration pushed or discarded local name");
  nativeName="Changed elsewhere";sync.rename(record.name,"Native title","Requested",success,failure);
  require(code=="conflict" && writes==0,"stale native name was overwritten");
  done=false;code="";sync.rename(record.name,nativeName,"Requested",success,failure);
  require(done && record.name=="Requested" && nativeName=="Requested" && metadata().source=="native","native rename did not confirm both stores");
  nativeName="Renamed in Codex";sync.observeExternal(nativeName);require(record.name=="Renamed in Codex","external native title was not imported");
  require(AgentMetadata.rename(record,record.name,"Pinned label",save)==null,"local label override failed");
  nativeName="Another native title";sync.observeExternal(nativeName);require(record.name=="Pinned label" && metadata().nativeName=="Another native title","external edit overwrote explicit local label");
  loseResponse=true;done=false;sync.rename(record.name,"Another native title","Recovered response",success,failure);
  require(done && record.name=="Recovered response" && writes==2,"lost response caused duplicate write or missed confirmed rename");
  loseResponse=false;done=false;failSaveAt=saves+2;
  sync.rename(record.name,nativeName,"Crash recovery",success,failure);
  require(code=="storage_unavailable" && ambiguous && durable.nameMetadata!=null && durable.nameMetadata.pending!=null && nativeName=="Crash recovery","native/local partial failure lost durable intent");
  sync.dispose();record=cast Reflect.copy(durable);failSaveAt=-1;done=false;
  sync=new AgentNameSync(record,save,read,write,function() return 0.0);
  var previousWrites=writes;sync.inspect(success,failure);
  require(done && record.name=="Crash recovery" && metadata().pending==null && writes==previousWrites,"restart replayed native write instead of reconciling");
  // A never-issued persisted intent is safely cleared on inspection without a write.
  record.nameMetadata={source:"native",nativeName:nativeName,pending:{expected:nativeName,target:"Never sent",session:record.thread}};save();
  sync.inspect(success,failure);require(record.name=="Crash recovery" && metadata().pending==null && writes==previousWrites,"unissued intent was automatically applied");
  failSaveAt=saves+1;sync.rename(record.name,nativeName,"Not sent",success,failure);
  require(writes==previousWrites && code=="storage_unavailable","failed intent persistence still wrote native title");
  trace("PASS: native naming migration, conflicts, explicit local labels, lost responses, durable intent and crash reconciliation without duplicate writes");
 }
}
