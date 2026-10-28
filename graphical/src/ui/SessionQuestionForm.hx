package ui;

import haxe.Json;
import haxeon.ui.Insets;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.TextStyleOverride;
import haxeon.ui.core.View;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.controls.Button;
import haxeon.ui.widgets.controls.Checkbox;
import haxeon.ui.widgets.controls.Radio;
import haxeon.ui.widgets.layout.Column;
import haxeon.ui.widgets.text.Text;
import haxeon.ui.widgets.text.TextField;
import workspace.service.WorkspaceAgentProtocol.AgentQuestion;

private typedef QuestionDraft = { var selected:Array<String>; var other:Bool; var custom:String; }

/** Request-scoped answers are independent of the ordinary message composer. */
class SessionQuestionForm implements View {
 final key:String; final frame:Void->Void; final submit:String->Void; final provider:String;
 var questions:Array<AgentQuestion>; var enabled:Bool;
 var drafts:Map<String,QuestionDraft> = [];
 var signature:String;
 var oversized:Bool=false; var commaRestricted:Bool=false;
 public function new(key:String, questions:Array<AgentQuestion>, enabled:Bool, frame:Void->Void, submit:String->Void, ?provider:String) {
  this.provider=provider; this.key=key; this.frame=frame; this.submit=submit; this.questions=questions; this.enabled=enabled;
  signature=Json.stringify(questions); initialize();
 }
 public function update(questions:Array<AgentQuestion>, enabled:Bool):Void {
  var next=Json.stringify(questions);
  if (next != signature) { signature=next; this.questions=questions; drafts=[]; initialize(); }
  else this.questions=questions;
  this.enabled=enabled;
 }
 function initialize():Void {
  if (questions == null) return;
  for (question in questions) drafts.set(question.id,{selected:[],other:question.options.length == 0,custom:""});
 }
 function payload():Null<String> {
  oversized=false; commaRestricted=false;
  if (!enabled || questions == null || questions.length == 0) return null;
  var result:Array<{id:String,answers:Array<String>}> = [];
  for (question in questions) {
   if (question.secret) return null;
   var draft=drafts.get(question.id);
   if (draft == null) return null;
   var answers:Array<String> = [];
   for (option in question.options) if (draft.selected.indexOf(option.label) >= 0) answers.push(option.label);
   if (draft.other && question.allowOther && StringTools.trim(draft.custom) != "") answers.push(draft.custom);
   if (answers.length == 0 || (!question.multiple && answers.length != 1)) return null;
   if (provider == "claude" && question.multiple) for (answer in answers) if (answer.indexOf(",") >= 0) {
    commaRestricted=true; return null;
   }
   result.push({id:question.id,answers:answers});
  }
  var encoded=Json.stringify(result);
  if (haxe.io.Bytes.ofString(encoded).length > 8192) { oversized=true; return null; }
  return encoded;
 }
 public function build(context:BuildContext):RenderNode {
  var tokens=context.theme.tokens, rows:Array<KeyedView> = [];
  if (questions != null) for (index in 0...questions.length) {
   var question=questions[index], draft:QuestionDraft=cast drafts.get(question.id);
   var children:Array<KeyedView> = [];
   if (question.header != "") children.push(new KeyedView("header",new Text(question.header,null,tokens.textSecondary,TextStyleOverride.text(12))));
   var questionStyle=new LayoutStyle(); questionStyle.width=LayoutAxis.grow();
   children.push(new KeyedView("question",new Text(question.question,questionStyle,tokens.textPrimary)));
   if (question.secret) children.push(new KeyedView("secret",new Text("Secret answers require a client with a protected input field.",questionStyle,tokens.textSecondary)));
   else {
    for (optionIndex in 0...question.options.length) {
     var option=question.options[optionIndex], selected=draft.selected.indexOf(option.label) >= 0;
     if (question.multiple) {
      var check=new Checkbox("question-"+index+"-option-"+optionIndex,option.label,selected,function(value) {
       if (value && draft.selected.indexOf(option.label) < 0) draft.selected.push(option.label);
       else if (!value) draft.selected.remove(option.label);
       frame();
      });
      check.enabled=enabled; children.push(new KeyedView("option-"+optionIndex,check));
     } else {
      var radio=new Radio("question-"+index+"-option-"+optionIndex,option.label,option.label,selected,
       function(_) { draft.selected=[option.label]; draft.other=false; frame(); },null,enabled);
      children.push(new KeyedView("option-"+optionIndex,radio));
     }
     if (option.description != "") {
      var description=new LayoutStyle(); description.width=LayoutAxis.grow(); description.padding=new Insets(30,0,0,4);
      children.push(new KeyedView("description-"+optionIndex,new Text(option.description,description,tokens.textSecondary,TextStyleOverride.text(12))));
     }
    }
    if (question.allowOther) {
     if (question.options.length > 0) {
      if (question.multiple) {
       var other=new Checkbox("question-"+index+"-other","Other",draft.other,function(value) { draft.other=value; frame(); });
       other.enabled=enabled; children.push(new KeyedView("other",other));
      } else {
       var other=new Radio("question-"+index+"-other","Other","other",draft.other,
        function(_) { draft.selected=[]; draft.other=true; frame(); },null,enabled);
       children.push(new KeyedView("other",other));
      }
     }
     if (question.options.length == 0 || draft.other) {
      var inputStyle=new LayoutStyle(); inputStyle.width=LayoutAxis.grow(); inputStyle.height=LayoutAxis.fixed(36);
      var input=new TextField("question-"+index+"-answer",draft.custom,function(value) { draft.custom=value; frame(); },inputStyle);
      input.label="Answer for "+(question.header == "" ? question.question : question.header);
      input.placeholder="Type your answer"; input.enabled=enabled;
      children.push(new KeyedView("custom",input));
     }
    }
   }
   var questionLayout=new LayoutStyle(); questionLayout.width=LayoutAxis.grow(); questionLayout.childGap=3;
   children.push(new KeyedView("space",new Text("")));
   rows.push(new KeyedView("question-"+index,new Column("question-"+index,children,questionLayout)));
  }
  var answer=payload();
  var button=new Button("Submit answers",null,function() { var current=payload(); if (current != null) submit(current); },key+"-submit");
  button.enabled=answer != null;
  rows.push(new KeyedView("submit",button));
  if (enabled && answer == null) rows.push(new KeyedView("hint",new Text(oversized ? "Answers exceed the 8 KiB limit." : commaRestricted ? "Claude multiple-choice answers cannot contain commas." : "Answer each question to continue.",null,tokens.textSecondary,TextStyleOverride.text(12))));
  var layout=new LayoutStyle(); layout.width=LayoutAxis.grow(); layout.childGap=8;
  return new Column(key,rows,layout).build(context);
 }
}
