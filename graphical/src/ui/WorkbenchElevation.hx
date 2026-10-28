package ui;

import haxeon.ui.Canvas;
import haxeon.ui.Color;
import haxeon.ui.Rect;
import haxeon.ui.ResolvedLayoutItem;
import haxeon.ui.style.ComputedStyle;
import haxeon.ui.style.Decoration;
import haxeon.ui.style.DecorationChain;
import haxeon.ui.style.StyleProperty;
import style.WorkbenchColors;

/** A crisp surface edge with a soft ambient shadow and a tight contact shadow. */
class WorkbenchElevation extends Decoration {
  final dark:Bool;
  final level:Int;

  public function new(dark:Bool, level:Int = 1) {
    super();
    this.dark = dark;
    this.level = level;
  }

  public static function surface(dark:Bool, level:Int = 1):DecorationChain
    return DecorationChain.of([new WorkbenchElevation(dark, level)]);

  override public function paint(canvas:Canvas, geometry:ResolvedLayoutItem, style:ComputedStyle):Void {
    if (geometry.width <= 2 || geometry.height <= 2) return;
    var radius = style.get(StyleProperty.RadiusTopLeft);
    var bounds = new Rect(0, 0, geometry.width, geometry.height);
    var offset = level >= 2 ? 8.0 : 3.0;
    var blur = level >= 2 ? 26.0 : 14.0;
    var spread = level >= 2 ? -5.0 : -3.0;
    canvas.drawBoxShadow(bounds, 0, offset, blur, spread, [radius, radius, radius, radius],
      Color.rgba(0, 0, 0, dark ? 0.42 : 0.10));
    canvas.drawBoxShadow(bounds, 0, 1, 3, 0, [radius, radius, radius, radius],
      Color.rgba(0, 0, 0, dark ? 0.30 : 0.06));
    var edge = style.get(StyleProperty.BorderColor);
    if (edge.alpha == 0) edge = ExosuitPalette.hex(dark ? WorkbenchColors.darkBorder : WorkbenchColors.lightBorder);
    var fill = style.get(StyleProperty.Background);
    canvas.fillRoundedRect(bounds, radius, edge);
    canvas.fillRoundedRect(new Rect(1, 1, geometry.width - 2, geometry.height - 2), Math.max(0, radius - 1), fill);
    // A restrained top rim gives the surface definition without a glossy gradient.
    if (geometry.width > radius * 2 + 2)
      canvas.fillRectIfPositive(new Rect(Math.max(1, radius), 1, geometry.width - Math.max(1, radius) * 2, 1),
        Color.rgba(1, 1, 1, dark ? 0.035 : 0.40));
  }

  override public function copy():Decoration return new WorkbenchElevation(dark, level);
  override public function isEqual(other:Decoration):Bool {
    if (!Std.isOfType(other, WorkbenchElevation)) return false;
    var value:WorkbenchElevation = cast other;
    return value.dark == dark && value.level == level;
  }
  override public function describe():String return "workbench-elevation(" + dark + "," + level + ")";
}
