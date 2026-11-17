package ui.control;

import haxeon.platform.event.EventPump;
import haxeon.platform.event.EventSubscription;
import haxeon.platform.event.PlatformEvent;
import nativekit.ffi.NativeKitTypes;
import suit.control.ControlError;

private typedef Action = {
	/** The steps; each is delivered on its own pass of the loop, so the UI sees a press and its release apart. */
	var steps:Array<Array<PlatformEvent>>;
	var done:(Null<Dynamic>, Null<ControlError>) -> Void;
	/** When it was queued, then when its last step went out: the user's input is waited out from here. */
	var since:Float;
	var delivered:Int;
}

/**
	Element input for a program that drives the window (docs/design/suitctl/TDD-exosuit-ctl.md §8.4 T6, Q10=b): pointer,
	key and text events dispatched into the window's own event pump, the path the OS's input takes once NativeKit decoded
	it. Nothing goes to the OS: the real mouse and keyboard are never moved, and the window is never raised.

	Real input always wins (Q19=b): an action waits while the user's own input reached the window in the last second.
	After 5 s of waiting it gives up: with `busy` (retryable) when nothing of it went out yet, else with `interrupted`
	(not retryable: part of it happened), after releasing the buttons it pressed. A control call that acts at once
	(`begin`) answers `busy` straight away instead. The window counts as driven from an injected event until the user's
	next input; a dialog opened meanwhile waits for `exosuit.dialog.answer` instead of showing (DrivenDialogs).
**/
class SyntheticInput {
	static inline final REAL_INPUT_SECONDS = 1.0;
	static inline final BUSY_SECONDS = 5.0;
	/** How long after the last driven step the window still counts as driven when the user does nothing. */
	static inline final DRIVEN_SECONDS = 5.0;

	final events:EventPump;
	final window:WindowHandle;
	final subscription:EventSubscription;
	final queue:Array<Action> = [];
	var injecting = false;
	var lastRealInput = -1.0;
	var lastDriven = -1.0;
	/** The pointer buttons a delivered step pressed and none released yet, with where. */
	final pressed:Array<{button:Int, x:Float, y:Float}> = [];
	/** Called after a step was delivered, so the window draws what it changed. */
	public var requestFrame:Void->Void = function() {};

	public function new(events:EventPump, window:WindowHandle) {
		this.events = events;
		this.window = window;
		subscription = events.listen(observe);
	}

	/** The user's own input: anything that reaches the window while this is not injecting. */
	function observe(value:PlatformEvent):Void {
		if (injecting)
			return;
		var source:Null<Handle> = switch value {
			case Key(source, _, _, _, _): source;
			case TextInput(source, _): source;
			case PointerMove(source, _, _): source;
			case PointerButton(source, _, _, _, _, _): source;
			case PointerScroll(source, _, _): source;
			default: null;
		}
		if (source != null && source.rawValue() == window.rawValue())
			lastRealInput = Sys.time();
	}

	/** Whether the window is being driven: injected input came after the user's last input, a few seconds ago at most. */
	public function driven():Bool
		return lastDriven > lastRealInput && Sys.time() - lastDriven < DRIVEN_SECONDS;

	/**
		A control call that acts at once like the user (a command, an answer, a focus): false after answering `busy` when
		the user's own input reached the window in the last second; else the window is now driven.
	**/
	public function begin(answer:(Null<Dynamic>, Null<ControlError>) -> Void):Bool {
		var now = Sys.time();
		if (now - lastRealInput < REAL_INPUT_SECONDS) {
			answer(null, busy());
			return false;
		}
		lastDriven = now;
		return true;
	}

	static function busy():ControlError
		return ControlError.retry("busy", "the user is typing or moving the mouse in this window; try again");

	/** A click: move there, press, release, `count` times. `button` is "left", "right" or "middle". */
	public function click(x:Float, y:Float, button:String, count:Int, done:(Null<Dynamic>, Null<ControlError>) -> Void):Void {
		var which = pointerButton(button);
		var steps:Array<Array<PlatformEvent>> = [[PointerMove(source(), x, y)]];
		for (_ in 0...count) {
			steps.push([PointerButton(source(), cast which, InputAction.Press, cast 0, x, y)]);
			steps.push([PointerButton(source(), cast which, InputAction.Release, cast 0, x, y)]);
		}
		enqueue(steps, done);
	}

	/** The pointer moved to a point and rests there (hover states, tooltips). */
	public function hover(x:Float, y:Float, done:(Null<Dynamic>, Null<ControlError>) -> Void):Void
		enqueue([[PointerMove(source(), x - 1, y)], [PointerMove(source(), x, y)]], done);

	/** Press at one point, move to another in steps, release there. */
	public function drag(fromX:Float, fromY:Float, toX:Float, toY:Float, done:(Null<Dynamic>, Null<ControlError>) -> Void):Void {
		var left = pointerButton("left");
		var steps:Array<Array<PlatformEvent>> = [[PointerMove(source(), fromX, fromY)], [PointerButton(source(), cast left, InputAction.Press, cast 0, fromX, fromY)]];
		for (index in 1...21)
			steps.push([PointerMove(source(), fromX + (toX - fromX) * index / 20, fromY + (toY - fromY) * index / 20)]);
		for (_ in 0...6)
			steps.push([PointerMove(source(), toX, toY)]); // a hover over the target, as a hand would hold
		steps.push([PointerButton(source(), cast left, InputAction.Release, cast 0, toX, toY)]);
		enqueue(steps, done);
	}

	/** Wheel notches over a point; negative scrolls down, as a wheel turned toward the user does. */
	public function scroll(x:Float, y:Float, notches:Int, done:(Null<Dynamic>, Null<ControlError>) -> Void):Void {
		var steps:Array<Array<PlatformEvent>> = [[PointerMove(source(), x, y)]];
		for (_ in 0...Std.int(Math.abs(notches)))
			steps.push([PointerScroll(source(), 0, notches > 0 ? 1 : -1)]);
		enqueue(steps, done);
	}

	/** Text as typed: one text input per code point, as a keyboard layout delivers it. */
	public function type(text:String, done:(Null<Dynamic>, Null<ControlError>) -> Void):Void {
		var steps:Array<Array<PlatformEvent>> = [];
		var index = 0;
		while (index < text.length) {
			var unit = StringTools.fastCodeAt(text, index++);
			if (unit >= 0xD800 && unit < 0xDC00 && index < text.length) {
				var low = StringTools.fastCodeAt(text, index);
				if (low >= 0xDC00 && low < 0xE000) {
					unit = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00);
					index++;
				}
			}
			// Enter, Tab and Backspace are keys, not text.
			steps.push(switch unit {
				case 10 | 13: keyPress(KEY_ENTER, 0);
				case 9: keyPress(KEY_TAB, 0);
				case 8: keyPress(KEY_BACKSPACE, 0);
				default: [TextInput(source(), unit)];
			});
		}
		enqueue(steps, done);
	}

	/** A chord such as `ctrl+shift+a`, `alt+up` or `enter`: the key pressed and released with the modifiers held. */
	public function key(chord:String, done:(Null<Dynamic>, Null<ControlError>) -> Void):Void {
		var parts = chord.toLowerCase().split("+");
		var modifiers = 0, code = -1;
		for (part in parts)
			switch part {
				case "ctrl" | "control": modifiers |= 1 << 1;
				case "shift": modifiers |= 1;
				case "alt": modifiers |= 1 << 2;
				case "super" | "win" | "cmd": modifiers |= 1 << 3;
				default:
					code = keyCode(part);
					if (code < 0) {
						done(null, new ControlError("invalid_argument", "unknown key " + part + " in " + chord));
						return;
					}
			}
		if (code < 0) {
			done(null, new ControlError("invalid_argument", "a chord needs one key: " + chord));
			return;
		}
		enqueue([keyPress(code, modifiers)], done);
	}

	static inline final KEY_ENTER = 257;
	static inline final KEY_TAB = 258;
	static inline final KEY_BACKSPACE = 259;

	/** NativeKit's key codes (nativekit_input.h): printable keys are their ASCII upper case. */
	static function keyCode(name:String):Int {
		if (name.length == 1) {
			var c = name.toUpperCase().charCodeAt(0);
			if (c >= 65 && c <= 90 || c >= 48 && c <= 57)
				return c;
			return switch name {
				case " ": 32;
				case ",": 44;
				case "-": 45;
				case ".": 46;
				case "/": 47;
				case ";": 59;
				case "=": 61;
				case "[": 91;
				case "\\": 92;
				case "]": 93;
				case "`": 96;
				default: -1;
			}
		}
		var functionKey = ~/^f([1-9][0-9]?)$/;
		if (functionKey.match(name)) {
			var number = Std.parseInt(functionKey.matched(1));
			return number >= 1 && number <= 25 ? 289 + number : -1;
		}
		return switch name {
			case "space": 32;
			case "esc" | "escape": 256;
			case "enter" | "return": KEY_ENTER;
			case "tab": KEY_TAB;
			case "backspace": KEY_BACKSPACE;
			case "insert": 260;
			case "delete": 261;
			case "right": 262;
			case "left": 263;
			case "down": 264;
			case "up": 265;
			case "pageup": 266;
			case "pagedown": 267;
			case "home": 268;
			case "end": 269;
			default: -1;
		}
	}

	function keyPress(code:Int, modifiers:Int):Array<PlatformEvent>
		return [Key(source(), cast code, 0, InputAction.Press, cast modifiers), Key(source(), cast code, 0, InputAction.Release, cast modifiers)];

	/** NativeKit's pointer buttons: left 0, right 1, middle 2. */
	static function pointerButton(name:String):Int
		return switch name { case "right": 1; case "middle": 2; default: 0; };

	function source():Handle
		return new Handle(window.rawValue());

	function enqueue(steps:Array<Array<PlatformEvent>>, done:(Null<Dynamic>, Null<ControlError>) -> Void):Void
		queue.push({steps: steps, done: done, since: Sys.time(), delivered: 0});

	/** Delivers the next step of the first action, unless the user's own input is too recent. Call every loop pass. */
	public function poll():Void {
		// haxeon throws on an index past the end, where stock Haxe gives null.
		if (queue.length == 0)
			return;
		var action = queue[0];
		var now = Sys.time();
		if (now - lastRealInput < REAL_INPUT_SECONDS) {
			if (now - action.since >= BUSY_SECONDS) {
				queue.shift();
				if (action.delivered == 0)
					action.done(null, busy());
				else {
					releasePressed();
					action.done(null, new ControlError("interrupted", "the user's input interrupted this after " + action.delivered + " of "
						+ (action.delivered + action.steps.length) + " steps; it is partly done"));
				}
			}
			return;
		}
		var step = action.steps.length > 0 ? action.steps.shift() : null;
		if (step != null) {
			try deliver(step) catch (error:Dynamic) {
				queue.shift();
				releasePressed();
				action.done(null, ControlError.internal(Std.string(error)));
				return;
			}
			action.delivered++;
			action.since = now;
			lastDriven = now;
			requestFrame();
		}
		if (action.steps.length == 0) {
			queue.shift();
			action.done({}, null);
		}
	}

	/** Dispatches one step's events as the window's own input, keeping `pressed` up to date. */
	function deliver(step:Array<PlatformEvent>):Void {
		injecting = true;
		try {
			for (value in step) {
				switch value {
					case PointerButton(_, button, action, _, x, y):
						var which:Int = cast button;
						for (index in 0...pressed.length)
							if (pressed[index].button == which) {
								pressed.splice(index, 1);
								break;
							}
						if (action == InputAction.Press) pressed.push({button: which, x: x, y: y});
					default:
				}
				events.dispatch(value);
			}
		} catch (error:Dynamic) {
			injecting = false;
			throw error;
		}
		injecting = false;
	}

	/** Releases what an abandoned action left pressed, where it was pressed, so the user's next move is not a drag. */
	function releasePressed():Void {
		var held = pressed.copy();
		pressed.resize(0);
		injecting = true;
		for (item in held)
			try events.dispatch(PointerButton(source(), cast item.button, InputAction.Release, cast 0, item.x, item.y)) catch (_:Dynamic) {}
		injecting = false;
		if (held.length > 0) requestFrame();
	}

	public function dispose():Void {
		subscription.dispose();
		for (action in queue)
			action.done(null, ControlError.internal("the window closed"));
		queue.resize(0);
	}
}
