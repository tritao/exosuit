package app;

import ui.TabHoverDelay;
import ui.TabTooltip;
import haxeon.ui.animation.AnimationScheduler;
import config.Settings;

class TabTooltipTestMain {
	static function require(value:Bool, message:String):Void { if (!value) throw message; }
	static function main():Int {
		var scheduler = new AnimationScheduler();
		var visible = false;
		var reveals = 0;
		var delay = new TabHoverDelay(scheduler, function(value) { visible = value; if (value) reveals++; });
		delay.start(); scheduler.advance(0.4);
		require(!visible, "tooltip appeared before the delay");
		delay.cancel(); scheduler.advance(1);
		require(!visible && scheduler.activeCount == 0, "leaving a tab did not cancel its pending tooltip");
		delay.start(); scheduler.advance(0.4); delay.cancel(); delay.start(); scheduler.advance(0.5);
		require(!visible, "reentering reused the previous hover's elapsed time");
		scheduler.advance(0.31);
		require(visible && reveals == 1 && scheduler.activeCount == 0, "deliberate hover did not reveal exactly once");
		delay.cancel(); require(!visible, "click/leave did not hide visible tooltip");
		delay.delaySeconds = 0.2; delay.start(); scheduler.advance(0.21);
		require(visible, "configured delay was ignored");
		delay.cancel(); delay.start(); delay.dispose(); scheduler.advance(2); delay.start();
		require(!visible && scheduler.activeCount == 0 && reveals == 2, "removed tab retained or restarted its timer");
		var left = TabTooltip.place(-50, 40, 0, 400);
		require(left.x == 56 && left.y == 44, "clipped tab tooltip was not anchored inside the rail");
		var right = TabTooltip.place(390, 52, 0, 400);
		require(right.x + 390 + right.width + 20 <= 394 && right.y == 56, "tooltip ignored rail edge or tab height");
		var narrow = TabTooltip.place(20, 40, 20, 100);
		require(narrow.width == 68 && narrow.x == 6, "tooltip padding was not included in width clamping");
		var settings = new Settings(); settings.tabTooltipDelay = 1.2;
		require(settings.copy().tabTooltipDelay == 1.2, "settings copy lost tooltip delay");
		trace("PASS: tooltip delay, cancellation, reentry, disposal, and rail clamping");
		return 0;
	}
}
