import haxeon.platform.event.EventPump;
import haxeon.platform.event.EventSubscription;
import haxeon.platform.event.PlatformEvent;
import haxeon.ui.FontCollection;
import haxeon.ui.FontFamily;
import haxeon.ui.host.UiHostContext;
import haxeon.ui.host.UiHostRuntime;
import haxeon.ui.host.UiHostSession;
import haxeon.ui.host.UiHostSession.UiHostLifecycle;
import nativekit.ffi.NativeKitTypes;

/**
	Runs ExosuitApp on a NativeKit surface that the Activity created. Every method runs on the Activity's UI thread,
	which owns NativeKit event polling; the GPU render thread presents the frame.
**/
class AndroidUiHost {
	final surface:SurfaceHandle;
	final events:EventPump;
	final fonts:FontCollection;
	final session:UiHostSession;
	final runtime:UiHostRuntime;
	final context:UiHostContext;
	final subscription:EventSubscription;
	var ready = false;
	var closed = false;
	/** Fingers currently down. A tap acts on what was under the finger at touch-down, so the layout does not move meanwhile. */
	var touchesDown = 0;
	var pendingSafeArea:Null<Array<Float>>;
	var pendingSince = 0.0;
	var now = 0.0;

	public function new(surfaceId:Int, width:Int, height:Int, framebufferWidth:Int, framebufferHeight:Int, scale:Float, regular:String,
			mono:String, appFilesRoot:String, credentials:Null<haxe.io.Bytes>, credentialsUnreadable:Bool) {
		surface = new SurfaceHandle(surfaceId);
		if (!surface.isValid()) throw "invalid surface";
		events = new EventPump();
		fonts = FontCollection.create();
		try {
			fonts.add(regular, FontFamily.Default);
			if (mono != "") fonts.add(mono, FontFamily.Monospace);
			// The bundled faces lack symbols the UI draws (chevrons, arrows); the desktop gets them from the system fonts too.
			fonts.addSystemFallbacks();
		} catch (error:Dynamic) {
			fonts.dispose();
			throw error;
		}
		session = new UiHostSession(function() {});
		context = new UiHostContext(fonts, events, function() {}, function() {});
		// A phone has no hovering pointer: tooltips would only appear after a tap and cover what was tapped.
		context.touchPrimary = true;
		haxeon.ui.widgets.overlays.Tooltip.hoverEnabled = false;
		// Android has no window object: the surface alone is the platform handle.
		runtime = new UiHostRuntime(session, context, WindowHandle.invalid(), surface, width, height);
		subscription = events.listen(handleEvent);
		try {
			runtime.start(function(created) return AndroidExosuitFactory.create(created, appFilesRoot, credentials, credentialsUnreadable));
			if (session.state == UiHostLifecycle.Failed) throw session.error;
			resize(width, height, framebufferWidth, framebufferHeight, scale);
		} catch (error:Dynamic) {
			subscription.dispose();
			runtime.dispose();
			fonts.dispose();
			throw error;
		}
	}

	function handleEvent(value:PlatformEvent):Void {
		switch value {
			case SurfaceReady(source) if (source.rawValue() == surface.rawValue()):
				ready = true;
				runtime.setSurfaceReady(true);
			case SurfaceLost(source) if (source.rawValue() == surface.rawValue()):
				ready = false;
				runtime.setSurfaceReady(false);
			case Touch(source, _, action, _, _, _, _, _, _, _) if (source.rawValue() == surface.rawValue()):
				if (action == TouchAction.Begin) touchesDown++;
				else if ((action == TouchAction.End || action == TouchAction.Cancel) && touchesDown > 0) touchesDown--;
			case SurfaceResize(source, width, height, fbWidth, fbHeight) if (source.rawValue() == surface.rawValue()):
				runtime.resize(width, height, fbWidth, fbHeight);
			case _:
		}
	}

	public function resize(width:Int, height:Int, framebufferWidth:Int, framebufferHeight:Int, scale:Float):Void {
		if (width <= 0 || height <= 0 || framebufferWidth <= 0 || framebufferHeight <= 0 || !Math.isFinite(scale) || scale <= 0)
			throw "invalid geometry";
		runtime.setScale(scale);
		runtime.resize(width, height, framebufferWidth, framebufferHeight);
	}

	/** Distances in logical pixels the system bars, cutout and keyboard cover; `bottom` already includes the keyboard. */
	public function setSafeArea(left:Float, top:Float, right:Float, bottom:Float, keyboard:Float):Void {
		// Touching a button while the keyboard is up takes focus off the field and hides the keyboard, which changes the
		// safe area and moves everything under the finger before it lifts. The click would then miss its button, so a
		// change that arrives mid-touch waits for the release (at most a second: a lost release must not freeze layout).
		if (touchesDown > 0) {
			if (pendingSafeArea == null) pendingSince = now;
			pendingSafeArea = [left, top, right, bottom, keyboard];
			return;
		}
		pendingSafeArea = null;
		context.setSafeArea(left, top, right, bottom, keyboard);
	}

	function applyPendingSafeArea():Void {
		var pending = pendingSafeArea;
		if (pending == null || (touchesDown > 0 && now - pendingSince < 1.0)) return;
		pendingSafeArea = null;
		touchesDown = 0;
		context.setSafeArea(pending[0], pending[1], pending[2], pending[3], pending[4]);
	}

	/** System Back: true when the application consumed it, false when the Activity should finish. */
	public function back():Bool return context.handleBack();

	public function frame(timeMs:Float):Void {
		if (closed) return;
		now = timeMs / 1000.0;
		while (events.poll()) {}
		applyPendingSafeArea();
		var poll = context.onPoll;
		if (poll != null) poll();
		if (!ready) return;
		runtime.render(timeMs / 1000.0);
		if (session.state == UiHostLifecycle.Failed) throw Std.string(session.error);
	}

	public function close():Void {
		if (closed) return;
		closed = true;
		subscription.dispose();
		runtime.dispose();
		fonts.dispose();
	}
}
