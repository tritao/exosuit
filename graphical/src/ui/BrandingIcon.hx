package ui;

import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.LayoutVisualKind;
import haxeon.ui.Color;
import haxeon.ui.Path;
import haxeon.ui.Paint.SolidPaint;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.View;

/** Decorative brand mark; the adjacent EXOSUIT label owns the accessible name. */
class BrandingIcon implements View {
	final background:Color;
	public function new(background:Color) { this.background = background; }
	public function build(context:BuildContext):RenderNode {
		var resources = context.resourceState(context.id("branding-paths:" + background.red + ":" + background.green + ":" + background.blue),
			function() return new BrandingPaths(background), function(value:BrandingPaths) value.dispose()).value;
		var style = new LayoutStyle();
		style.width = LayoutAxis.fixed(22);
		style.height = LayoutAxis.fixed(22);
		var node = new RenderNode(context.id("exosuit-brand-icon"), LayoutVisualKind.Custom, style);
		node.setStyleIdentity("brand-icon", "exosuit-brand-icon");
		node.hitTestSelf = false;
		node.onPaint(function(canvas, geometry) {
			canvas.withState(function(target) {
				target.scale(geometry.width / 48, geometry.height / 48);
				target.translate(-8, -9);
				target.fill(resources.shell, resources.blue);
				// The canvas currently exposes solid path fills. Match the titlebar
				// behind the code cutouts, preserving their native curved edges.
				target.fill(resources.cutouts, resources.background);
			});
		});
		return node;
	}
}

private class BrandingPaths {
	public final shell:Path;
	public final cutouts:Path;
	public final blue:SolidPaint;
	public final background:SolidPaint;
	public function new(background:Color) {
		shell = BrandingIconData.createShell();
		cutouts = BrandingIconData.createCutouts();
		blue = SolidPaint.create(Color.rgba(75 / 255, 127 / 255, 242 / 255, 1));
		this.background = SolidPaint.create(background);
	}
	public function dispose():Void {
		shell.dispose(); cutouts.dispose(); blue.dispose(); background.dispose();
	}
}
