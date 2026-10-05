package ui;

import nativekit.ui.core.BuildContext;
import nativekit.ui.core.RenderNode;
import nativekit.ui.core.UiEvent;
import nativekit.ui.core.UiEventKind;
import nativekit.ui.core.UiKey;
import nativekit.ui.core.UiModifier;
import nativekit.ui.core.View;
import platform.Platform;

/**
 * Wraps an overlay's content so `UiWorkbenchHost`'s command-view / language
 * popup state machines - both plain `Int` key/modifier state machines
 * written for the headless host - can drive uikit input the same way they
 * drive `platform.Native` key events there. Requests keyboard focus for its
 * child on first build (so the overlay - not whatever editor tab was
 * focused before it opened - receives the keys) and forwards every
 * `KeyDown`/`KeyRepeat`/`TextInput` uikit dispatches to it to `onKey`/`onText`,
 * consuming the event when `onKey` reports it handled the chord.
 */
class KeyCaptureView implements View {
	final child:View;
	final onKey:(Int, Int) -> Bool;
	final onText:String->Void;
	final onPreedit:Null<UiEvent->Void>;
	var requestedFocus:Bool = false;

	public function new(child:View, onKey:(Int, Int) -> Bool, onText:String->Void, ?onPreedit:UiEvent->Void) {
		this.child = child;
		this.onKey = onKey;
		this.onText = onText;
		this.onPreedit = onPreedit;
	}

	public function build(context:BuildContext):RenderNode {
		var node = child.build(context);
		node.focusable = true;
		var handleKey = function(event:UiEvent) {
			if (onKey(translateKey(event.key), translateModifiers(event.modifiers)))
				event.preventDefault();
		};
		node.on(UiEventKind.KeyDown, handleKey);
		node.on(UiEventKind.KeyRepeat, handleKey);
		node.on(UiEventKind.TextInput, function(event:UiEvent) {
			if (event.text != null && event.text.length > 0) onText(event.text);
			event.preventDefault();
		});
		if (onPreedit != null) node.on(UiEventKind.TextEdit, function(event:UiEvent) {
			if (onPreedit != null) onPreedit(event);
			event.preventDefault();
		});
		if (!requestedFocus) {
			context.requestFocusAfterLayout(node.id);
			requestedFocus = true;
		}
		return node;
	}

	/** Resets so the next build re-requests focus (call when an overlay reopens). */
	public function resetFocus():Void
		requestedFocus = false;

	static function translateKey(key:Int):Int
		return switch key {
			case UiKey.Escape: Platform.KEY_ESCAPE;
			case UiKey.Enter: Platform.KEY_ENTER;
			case UiKey.Tab: Platform.KEY_TAB;
			case UiKey.Backspace: Platform.KEY_BACKSPACE;
			case UiKey.Delete: Platform.KEY_DELETE;
			case UiKey.Down: Platform.KEY_DOWN;
			case UiKey.Up: Platform.KEY_UP;
			case UiKey.PageUp: Platform.KEY_PAGE_UP;
			case UiKey.PageDown: Platform.KEY_PAGE_DOWN;
			case UiKey.Right: Platform.KEY_RIGHT;
			case UiKey.Left: Platform.KEY_LEFT;
			case UiKey.Home: Platform.KEY_HOME;
			case UiKey.End: Platform.KEY_END;
			case UiKey.A: Platform.KEY_A;
			case UiKey.C: Platform.KEY_C;
			case UiKey.S: Platform.KEY_S;
			case UiKey.Y: Platform.KEY_Y;
			case UiKey.Z: Platform.KEY_Z;
			case UiKey.V: Platform.KEY_V;
			case UiKey.X: Platform.KEY_X;
			case UiKey.Space: Platform.KEY_SPACE;
			default: Platform.KEY_UNKNOWN;
		};

	static function translateModifiers(modifiers:Int):Int {
		var result = 0;
		if ((modifiers & UiModifier.Shift) != 0) result |= Platform.MOD_SHIFT;
		if ((modifiers & UiModifier.Control) != 0) result |= Platform.MOD_CTRL;
		if ((modifiers & UiModifier.Alt) != 0) result |= Platform.MOD_ALT;
		// uikit's UiModifier.Super has no Platform.MOD_* counterpart (the
		// headless key model predates any notion of a Cmd/Super chord); a
		// Super-modified chord is reported with that bit dropped.
		return result;
	}
}
