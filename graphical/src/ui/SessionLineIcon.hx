package ui;

import haxeon.ui.Color;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.LayoutVisualKind;
import haxeon.ui.LineCap;
import haxeon.ui.LineJoin;
import haxeon.ui.PathBuilder;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.View;

/** Small decorative line icons for the session composer. */
class SessionLineIcon implements View {
  final name:String;
  final color:Color;
  public function new(name:String, color:Color) { this.name = name; this.color = color; }
  public function build(context:BuildContext):RenderNode {
    var style = new LayoutStyle(); style.width = LayoutAxis.fixed(16); style.height = LayoutAxis.fixed(16);
    var node = new RenderNode(context.id("session-icon-" + name), LayoutVisualKind.Custom, style);
    node.hitTestSelf = false;
    node.onPaint(function(canvas, geometry) {
      var p = new PathBuilder();
      switch name {
        case "model":
          p.moveTo(12,3).cubicTo(16,3,19,6,19,10).cubicTo(19,14,16,16,12,16)
            .cubicTo(8,16,6,13,6,10).cubicTo(6,7,8,5,11,5)
            .cubicTo(15,5,17,8,17,11).cubicTo(17,15,14,19,10,20)
            .cubicTo(6,20,3,17,3,13).cubicTo(3,9,6,6,10,6);
        case "reasoning":
          p.moveTo(12,5).cubicTo(10,2,6,4,6,7).cubicTo(3,7,3,11,5,12)
            .cubicTo(3,15,6,18,8,17).cubicTo(8,20,11,20,12,18)
            .cubicTo(13,20,16,20,16,17).cubicTo(19,18,21,15,19,12)
            .cubicTo(21,10,20,7,18,7).cubicTo(18,4,14,2,12,5)
            .moveTo(12,5).lineTo(12,18).moveTo(6,9).cubicTo(8,9,9,10,9,12)
            .moveTo(18,9).cubicTo(16,9,15,10,15,12);
        case "lock":
          p.roundRect(5,10,14,10,2).moveTo(8,10).lineTo(8,7)
            .cubicTo(8,2,16,2,16,7).lineTo(16,10).moveTo(12,14).lineTo(12,16);
        case "attachment":
          p.moveTo(9,12).lineTo(15,6).cubicTo(19,2,23,7,19,11)
            .lineTo(11,19).cubicTo(7,23,2,18,6,14).lineTo(14,6);
        case "worktree":
          p.moveTo(3,7).lineTo(10,7).lineTo(12,9).lineTo(21,9).lineTo(21,19)
            .lineTo(3,19).close().moveTo(3,7).lineTo(3,5).lineTo(10,5).lineTo(12,7);
        case "branch":
          p.roundRect(4,3,4,4,2).roundRect(16,3,4,4,2).roundRect(4,17,4,4,2)
            .moveTo(6,7).lineTo(6,17).moveTo(18,7).lineTo(18,9)
            .cubicTo(18,13,13,13,10,13).lineTo(6,13);
        default: p.moveTo(4,12).lineTo(20,12);
      }
      canvas.withState(function(target) {
        target.scale(geometry.width / 24, geometry.height / 24);
        target.strokeTransient(p.build(), color, 1.8, LineCap.Round, LineJoin.Round);
      });
    }, "session-icon:" + name + ":" + color.red + ":" + color.green + ":" + color.blue + ":" + color.alpha);
    return node;
  }
}
