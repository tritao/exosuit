package ui;

import haxeon.ui.animation.Animation;
import haxeon.ui.animation.AnimationScheduler;

/** Shared hover timing lets neighboring labels switch without restarting the delay. */
class TooltipHoverGroup implements Animation {
	final scheduler:AnimationScheduler;
	final changed:Null<String>->Void;
	var hovered:Null<String>;
	var visible:Null<String>;
	var remaining:Float = 0;
	public var delaySeconds:Float;

	public function new(scheduler:AnimationScheduler, changed:Null<String>->Void, delaySeconds:Float) {
		this.scheduler = scheduler;
		this.changed = changed;
		this.delaySeconds = delaySeconds;
	}

	public function enter(key:String):Void {
		hovered = key;
		if (visible != null || delaySeconds <= 0) {
			scheduler.remove(this);
			show(key);
		} else {
			remaining = delaySeconds;
			scheduler.track(this);
		}
	}

	public function leave(key:String):Void {
		if (hovered != key) return;
		hovered = null;
		if (visible == null) scheduler.remove(this);
		else {
			remaining = 0.4;
			scheduler.track(this);
		}
	}

	public function cancel():Void {
		hovered = null;
		scheduler.remove(this);
		show(null);
	}

	function show(key:Null<String>):Void {
		visible = key;
		changed(key);
	}

	public function advance(deltaSeconds:Float):Bool {
		remaining -= deltaSeconds;
		if (remaining > 0) return true;
		show(hovered);
		return false;
	}

	public function dispose():Void scheduler.remove(this);
}
