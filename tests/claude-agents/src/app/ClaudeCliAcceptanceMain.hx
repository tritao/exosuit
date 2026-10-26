package app;

import workspace.provider.ClaudeTransport;
import process.ProcessManager;

/** Opt-in inference acceptance using the production native Haxe transport. */
class ClaudeCliAcceptanceMain {
 static function require(ok:Bool,message:String):Void {if(!ok) throw message;}
 static function main():Void {
  var args=Sys.args(),root=args[0],executable=args[1];
  var processes=new ProcessManager(),clock=function() return Sys.time()*1000;
  var launch=["-p","--input-format","stream-json","--output-format","stream-json","--verbose","--include-partial-messages",
   "--permission-prompt-tool","stdio","--settings",'{"permissions":{"ask":["Write","Bash","AskUserQuestion"]}}'];
  var process=processes.start(executable,launch,root),transport=new ClaudeTransport(process);
  var stage=0,session="",approved=false,answered=false,interrupted=false,resumed=false,initialized=false;
  var deadline=clock()+180000;
  function prompt(text:String):Void {
   require(transport.send({type:"user",message:{role:"user",content:text}}),"Prompt queue failed");
  }
  transport.serverRequest=function(id,subtype,request) {
   require(subtype=="can_use_tool","Unexpected server request");
   var tool:String=Reflect.field(request,"tool_name"),input=Reflect.field(request,"input");
   if(tool=="Write") {approved=true;require(transport.respond(id,{behavior:"allow",updatedInput:input}),"Approval failed");}
   else if(tool=="AskUserQuestion") {
    var questions:Array<Dynamic>=Reflect.field(input,"questions"),answers:Dynamic={};
    for(q in questions) Reflect.setField(answers,Reflect.field(q,"question"),"Blue");
    Reflect.setField(input,"answers",answers);answered=true;
    require(transport.respond(id,{behavior:"allow",updatedInput:input}),"Question response failed");
   } else if(tool=="Bash" && stage==2) {
    // Interrupt the actual tool, after acknowledging this harmless sleep command.
    require(transport.respond(id,{behavior:"allow",updatedInput:input}),"Sleep approval failed");
    transport.request("interrupt",{},clock(),function(r) {require(r.error==null,"Interrupt control failed");interrupted=true;});stage=3;
   } else require(transport.respond(id,{behavior:"deny",message:"Only acceptance fixture actions are authorized"}),"Deny failed");
  };
  transport.notification=function(type,v) {
   if(type=="system" && Reflect.field(v,"subtype")=="init") session=Reflect.field(v,"session_id");
   if(type=="result" && stage==1) {
    require(approved && answered,"CLI did not request both approval and a user answer");
    prompt("Use Bash to run sleep 30, then reply DONE.");stage=2;
   } else if(type=="result" && stage==3) stage=4;
  };
  transport.request("initialize",{},clock(),function(r) {
   require(r.error==null,"Initialization failed");initialized=true;
   prompt("Use Write to write EXOSUIT_APPROVAL_OK into "+root+"/approved.txt. Do not use Bash. Then use AskUserQuestion to ask which color I prefer, with Red and Blue as options. Do not guess the answer.");stage=1;
  });
  while(stage!=4 || !interrupted) {
   require(clock()<deadline,"Real Claude acceptance timed out");transport.poll(clock());
   require(transport.failure==null,"Real Claude transport failed: "+transport.failure);Sys.sleep(0.005);
  }
  require(initialized && session!="" && sys.io.File.getContent(root+"/approved.txt").indexOf("EXOSUIT_APPROVAL_OK")>=0,"Approval fixture not written");
  transport.close("Acceptance reconnect");processes.release(process);
  process=processes.start(executable,launch.concat(["--resume",session]),root);transport=new ClaudeTransport(process);
  var response="",done=false,modelSet=false,modeSet=false;
  transport.notification=function(type,v) {
   if(type=="assistant") {
    var message=Reflect.field(v,"message"),parts:Array<Dynamic>=Reflect.field(message,"content");
    if(parts!=null) for(part in parts) if(Reflect.field(part,"type")=="text") response+=Reflect.field(part,"text");
   }
   if(type=="result") {resumed=response.toLowerCase().indexOf("blue")>=0;done=true;}
  };
  transport.request("initialize",{},clock(),function(r) {
   require(r.error==null,"Resume initialize failed");
   transport.request("set_permission_mode",{mode:"default"},clock(),function(r) {require(r.error==null,"Permission control failed");modeSet=true;});
   transport.request("set_model",{model:"default"},clock(),function(r) {
    require(r.error==null,"Model control failed");modelSet=true;
    prompt("What color did I choose earlier? Reply with only the color.");
   });
  });
  while(!done) {
   require(clock()<deadline,"Resume timed out");transport.poll(clock());require(transport.failure==null,"Resume transport failed: "+transport.failure);Sys.sleep(0.005);
  }
  require(resumed && modelSet && modeSet,"Resumed Claude did not remember the answer or acknowledge settings");
  transport.close("Acceptance complete");processes.shutdown();
  Sys.println("PASS: real Claude native Haxe initialize, streamed prompt, approval, user question, interrupt, explicit resume, model and permission controls");
 }
}
