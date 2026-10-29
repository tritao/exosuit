package app;

import haxeon.ui.FontCollection;
import haxeon.ui.LayoutFrame;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiContext;
import haxeon.ui.core.UiEventKind;
import haxeon.ui.core.UiKey;
import ui.SessionQuestionForm;
import workspace.service.WorkspaceAgentProtocol.AgentQuestion;

/** Real UI events exercise selections, independent drafts, validation and submission. */
class SessionQuestionFormTest {
 static function require(value:Bool,message:String):Void if (!value) throw message;
 static function find(root:RenderNode,label:String):RenderNode {
  var found:RenderNode=null;
  root.walk(function(node) { if (found == null && node.semantics != null && node.semantics.label == label) found=node; });
  if (found == null) throw "Missing question control: "+label;
  return found;
 }
 static function click(context:UiContext,node:RenderNode):Void {
  var b=node.globalBounds();
  require(b.width>=20 && b.height>=20,"Question control is too small");
  context.pointerDown(b.x+b.width/2,b.y+b.height/2,0);
  context.pointerUp(b.x+b.width/2,b.y+b.height/2,0);
 }
 public static function run(fonts:FontCollection):Void {
  var context=new UiContext(null,fonts,ui.ExosuitPalette.theme(true));
  var values:Array<AgentQuestion>=[
   {id:"a",header:"Mode",question:"Choose a mode",multiple:false,secret:false,allowOther:true,
    options:[{label:"Fast",description:"Shortest run"},{label:"Careful, thorough",description:"Checks more"}]},
   {id:"b",header:"Checks",question:"Which checks?",multiple:true,secret:false,allowOther:true,
    options:[{label:"Build",description:""},{label:"Tests",description:""}]}
  ];
  var submitted:String=null;
  var form=new SessionQuestionForm("fixture-question",values,true,function(){},function(text) submitted=text);
  function build():RenderNode return context.submit(form,new LayoutFrame(500,900));
  var root=build();
  require(!find(root,"Submit answers").enabled,"Incomplete questions could be submitted");
  var careful=find(root,"Careful, thorough"); require(context.focusWidget(careful.id),"Radio cannot receive keyboard focus");
  context.key(UiEventKind.KeyDown,UiKey.Space); root=build();
  click(context,find(root,"Build")); root=build(); click(context,find(root,"Tests")); root=build();
  click(context,find(root,"Submit answers"));
  var parsed:Array<Dynamic>=cast haxe.Json.parse(submitted);
  var first:Array<String>=cast Reflect.field(parsed[0],"answers"), second:Array<String>=cast Reflect.field(parsed[1],"answers");
  require(first.length == 1 && first[0] == "Careful, thorough" && second.length == 2 && second[0] == "Build" && second[1] == "Tests",
   "Question answers lost option identity or order");
  submitted=null; form.update(values,true); root=build(); click(context,find(root,"Submit answers"));
  require(submitted != null,"Rerender discarded an unacknowledged draft");
  root=build(); click(context,find(root,"Other")); root=build();
  require(context.focusWidget(find(root,"Answer for Mode").id),"Custom answer cannot receive focus");
  context.text(UiEventKind.TextInput,"my own answer"); root=build(); click(context,find(root,"Submit answers"));
  parsed=cast haxe.Json.parse(submitted); first=cast Reflect.field(parsed[0],"answers");
  require(first.length==1 && first[0]=="my own answer", "Custom answer was not submitted");
  form.update([{id:"secret",header:"Secret",question:"Enter secret",multiple:false,secret:true,allowOther:true,options:[]}],true);
  root=build(); find(root,"Secret answers require a client with a protected input field.");
  require(!find(root,"Submit answers").enabled,"Unmasked secret could be submitted");
  context.dispose();
  var claudeContext=new UiContext(null,fonts,ui.ExosuitPalette.theme(true));
  var claudeQuestions:Array<AgentQuestion>=[
   {id:"single",header:"Single",question:"Select one",multiple:false,secret:false,allowOther:false,
    options:[{label:"With, comma",description:""}]},
   {id:"multi",header:"Multiple",question:"Add a custom value",multiple:true,secret:false,allowOther:true,options:[]}
  ];
  var claudeForm=new SessionQuestionForm("claude-question",claudeQuestions,true,function(){},function(_) {},"claude");
  function claudeBuild():RenderNode return claudeContext.submit(claudeForm,new LayoutFrame(500,600));
  var claudeRoot=claudeBuild(); click(claudeContext,find(claudeRoot,"With, comma")); claudeRoot=claudeBuild();
  require(claudeContext.focusWidget(find(claudeRoot,"Answer for Multiple").id),"Claude custom field cannot focus");
  claudeContext.text(UiEventKind.TextInput,"one, two"); claudeRoot=claudeBuild();
  require(!find(claudeRoot,"Submit answers").enabled,"Claude comma-separated multiple answer accepted");
  find(claudeRoot,"Claude multiple-choice answers cannot contain commas.");
  claudeForm.update([{id:"single",header:"Single",question:"Select one",multiple:false,secret:false,allowOther:false,
    options:[{label:"With, comma",description:""}]}],true);
  claudeRoot=claudeBuild(); click(claudeContext,find(claudeRoot,"With, comma")); claudeRoot=claudeBuild();
  require(find(claudeRoot,"Submit answers").enabled,"Claude single answer with comma was incorrectly rejected");
  claudeContext.dispose();
  Sys.println("PASS: question choices, keyboard, custom input, draft retention and secret protection");
 }
}
