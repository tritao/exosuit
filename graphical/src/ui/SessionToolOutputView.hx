package ui;

import haxeon.ui.FontFamily;
import haxeon.ui.Insets;
import haxeon.ui.LayoutAlignmentY;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.TextStyle;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Key;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.TextStyleOverride;
import haxeon.ui.core.View;
import haxeon.ui.icons.IconName;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.controls.Button;
import haxeon.ui.widgets.controls.ButtonVariant;
import haxeon.ui.widgets.layout.Column;
import haxeon.ui.widgets.layout.Row;
import haxeon.ui.widgets.scroll.ScrollAxis;
import haxeon.ui.widgets.scroll.ScrollView;
import haxeon.ui.widgets.text.Text;
import haxeon.ui.widgets.text.TextArea;

/** Selectable, bounded output with a verbatim copy action. */
class SessionToolOutputView implements View {
 final key:String; final source:String; final partial:Bool; final copy:Null<String->Void>;
 public function new(key:String,source:String,partial:Bool,?copy:String->Void) {
  this.key=key;this.source=source;this.partial=partial;this.copy=copy;
 }
 public function build(context:BuildContext):RenderNode return context.withScope(new Key(key),function() {
  var tokens=context.theme.tokens, copied=context.state(context.id("copied"),"");
  var actionStyle=new LayoutStyle();actionStyle.height=LayoutAxis.fixed(30);actionStyle.padding=new Insets(8,4,8,4);
  var action=new Button("",actionStyle,function() {
   if (copy == null) context.clipboard.writeText(source); else {var send:String->Void=cast copy;send(source);}
   copied.update(source);
  },key+"-copy");
  action.accessibilityLabel=copied.value==source ? "Copied output" : partial ? "Copy output preview" : "Copy output";
  action.leadingIcon=copied.value==source ? IconName.Check : IconName.Copy;action.iconSize=16;
  action.variant=ButtonVariant.Navigation;action.classes.push("viewport-tool");
  var heading=new LayoutStyle();heading.width=LayoutAxis.grow();heading.childGap=8;heading.childAlignY=LayoutAlignmentY.Center;
  var label=new LayoutStyle();label.width=LayoutAxis.grow();
  var lines=source.split("\n"),longest=0;for (line in lines) if (line.length>longest) longest=line.length;
  var body=new LayoutStyle();body.width=LayoutAxis.fixed(Math.max(280,longest*8+24));
  body.height=LayoutAxis.fixed(Math.max(40,lines.length*21+12));body.padding=new Insets(8,6,8,6);
  var field=new TextArea(key+"-text",source,null,body,"Tool output",new TextStyle(13,FontFamily.Monospace),tokens.textPrimary);
  field.readOnly=true;
  var viewport=new LayoutStyle();viewport.width=LayoutAxis.grow();viewport.height=LayoutAxis.fixed(Math.min(280,Math.max(40,lines.length*21+12)));
  var scroll=new ScrollView(key+"-scroll",field,viewport,ScrollAxis.Both);scroll.fillViewport=true;
  var card=new LayoutStyle();card.width=LayoutAxis.grow();card.childGap=4;card.padding=new Insets(8,6,8,6);card.background=tokens.surfaceSunken;
  card.radiusTopLeft=card.radiusTopRight=card.radiusBottomLeft=card.radiusBottomRight=5;
  var edge=new LayoutStyle();edge.width=LayoutAxis.grow();edge.padding=new Insets(1,1,1,1);edge.background=WorkbenchBoundary.color(context);
  edge.radiusTopLeft=edge.radiusTopRight=edge.radiusBottomLeft=edge.radiusBottomRight=6;
  return new Column(key+"-frame",[new KeyedView("card",new Column(key+"-card",[
    new KeyedView("heading",new Row(key+"-heading",[new KeyedView("label",new Text(partial ? "Output · preview" : "Output",label,tokens.textSecondary,TextStyleOverride.text(12))),
      new KeyedView("copy",action)],heading)),new KeyedView("output",scroll)
  ],card))],edge).build(context);
 });
}
