package ui;

import haxeon.ui.animation.Animation;
import haxeon.ui.animation.AnimationScheduler;

class TabHoverDelay implements Animation {
	final scheduler:AnimationScheduler;
	final changed:Bool->Void;
	var remaining:Float = 0;
	var pending:Bool = false;
	var disposed:Bool = false;
	public var delaySeconds:Float;
	public function new(scheduler:AnimationScheduler, changed:Bool->Void, delaySeconds:Float = 0.8) {
		this.delaySeconds = delaySeconds;
		this.scheduler = scheduler; this.changed = changed;
	}
	public function start():Void {
		if (disposed) return;
		pending = true;
		remaining = delaySeconds;
		changed(false);
		scheduler.track(this);
	}
	public function cancel():Void {
		pending = false;
		remaining = 0;
		scheduler.remove(this);
		changed(false);
	}
	public function advance(deltaSeconds:Float):Bool {
		if (!pending || disposed) return false;
		remaining -= deltaSeconds;
		if (remaining > 0) return true;
		pending = false;
		changed(true);
		return false;
	}
	public function dispose():Void { disposed = true; pending = false; scheduler.remove(this); }
}
