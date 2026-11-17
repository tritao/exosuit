package probes;

import haxeon.reactive.Signal;
import haxeon.ui.FontCollection;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutDirection;
import haxeon.ui.LayoutFrame;
import haxeon.ui.LayoutStyle;
import haxeon.ui.LayoutVisualKind;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Key;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiContext;
import haxeon.ui.core.View;
import haxeon.ui.core.WidgetId;
import haxeon.ui.semantics.AccessibilityRole;

/**
	The frame loop the port gives ExosuitApp (plan D1), headless: a `frameTick` signal that `view()` reads first, a
	`requestFrame()` that bumps it and asks the host for a frame, one `view` closure kept in a field, and a constant cache key.
	`hostFrames` counts what would reach the host: `requestFrame()`/`scheduleFrame()` calls and the context's own
	`onAnimationFrameRequested` (self-updating builds, render scopes, text bindings).
**/
class Harness {
	public static inline var ROOT_KEY = "root";

	public final ui:UiContext;
	public final frameTick = new Signal<Int>(0);
	public final frame:LayoutFrame;
	/** What the root view builds; called inside the root build. */
	public var body:BuildContext->Array<View>;
	public var rootBuilds(default, null):Int = 0;
	public var hostFrames(default, null):Int = 0;
	/** Frames the context asked for by itself (`onAnimationFrameRequested`). */
	public var selfFrames(default, null):Int = 0;
	public var root(default, null):Null<RenderNode>;
	final view:Void->View;

	public function new(fonts:FontCollection, body:BuildContext->Array<View>, width:Float = 480, height:Float = 360) {
		ui = new UiContext(null, fonts);
		ui.buildContext.environment.reducedMotion = true;
		this.body = body;
		frame = new LayoutFrame(width, height);
		var rootView = new RootView(this);
		view = function() {
			frameTick.value;
			return rootView;
		};
		ui.onAnimationFrameRequested = function() {
			selfFrames++;
			hostFrames++;
		};
	}

	/** ExosuitApp.requestFrame after D1: bump the tick, schedule a host frame. */
	public function requestFrame():Void {
		frameTick.value = frameTick.value + 1;
		hostFrames++;
	}

	/** ExosuitApp.scheduleFrame (contract C2): a host frame, no tick. */
	public function scheduleFrame():Void hostFrames++;

	/** One host frame: `submitCached` with the stable closure and the constant key. */
	public function submit():RenderNode {
		root = ui.submitCached(view, frame, ROOT_KEY);
		return root;
	}

	/** One host frame with a caller-chosen key (the pre-port string key). */
	public function submitKeyed(key:String):RenderNode {
		root = ui.submitCached(view, frame, key);
		return root;
	}

	@:allow(probes.RootView) function built():Void rootBuilds++;

	public function dispose():Void ui.dispose();

	// Tree queries.

	public static function hasText(root:RenderNode, value:String):Bool {
		var found = false;
		root.walk(function(node) {
			if (node.layout.text == value && visibleChain(node)) found = true;
		});
		return found;
	}

	public static function textStartingWith(root:RenderNode, prefix:String):Null<String> {
		var found:Null<String> = null;
		root.walk(function(node) {
			var text = node.layout.text;
			if (found == null && text != null && StringTools.startsWith(text, prefix) && visibleChain(node)) found = text;
		});
		return found;
	}

	public static function visibleChain(node:RenderNode):Bool {
		var current:Null<RenderNode> = node;
		while (current != null) {
			if (!current.layout.style.visible) return false;
			current = current.parent;
		}
		return true;
	}

	public static function byRole(root:RenderNode, role:AccessibilityRole, ?label:String):Array<RenderNode> {
		var nodes:Array<RenderNode> = [];
		root.walk(function(node) {
			var semantics = node.semantics;
			if (semantics != null && semantics.role == role && (label == null || semantics.label == label)) nodes.push(node);
		});
		return nodes;
	}

	public static function first(root:RenderNode, role:AccessibilityRole, ?label:String):RenderNode {
		var nodes = byRole(root, role, label);
		if (nodes.length == 0) throw "No " + Std.string(role) + " node" + (label == null ? "" : " labelled " + label);
		return nodes[0];
	}

	public static function sameId(a:Null<WidgetId>, b:Null<WidgetId>):Bool
		return a == null ? b == null : b != null && a.equals(b);

	public function click(node:RenderNode):Void {
		var bounds = node.globalBounds();
		ui.pointerMove(bounds.x + bounds.width / 2, bounds.y + bounds.height / 2);
		ui.pointerDown(bounds.x + bounds.width / 2, bounds.y + bounds.height / 2, 0);
		ui.pointerUp(bounds.x + bounds.width / 2, bounds.y + bounds.height / 2, 0);
	}
}

/** A vertical box holding the harness body, built in the root scope. */
private class RootView implements View {
	final harness:Harness;

	public function new(harness:Harness) this.harness = harness;

	public function build(context:BuildContext):RenderNode {
		harness.built();
		var style = new LayoutStyle();
		style.width = LayoutAxis.fixed(harness.frame.width);
		style.height = LayoutAxis.fixed(harness.frame.height);
		style.direction = LayoutDirection.TopToBottom;
		var node = context.createNode(context.id("probe-root"), LayoutVisualKind.Box, style);
		var index = 0;
		for (child in harness.body(context)) {
			var key = "child-" + index++;
			node.add(context.withScope(new Key(key), function() return child.build(context)));
		}
		return node;
	}
}
