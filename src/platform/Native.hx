package platform;

import platform.ffi.NativeApi;
import platform.ffi.NativeTypes.DispatchCallback;

/** Headless model ABI and process services. UIKit owns the graphical host. */
class Native {
	static var dispatchCallback:Null<DispatchCallback>;

	public static function plugin_api_install(dispatch:(Int, String, String, String, String)->String):Void {
		var replacement = new DispatchCallback(dispatch);
		NativeApi.pragtical_hx_plugin_api_install(replacement);
		var retired = dispatchCallback;
		dispatchCallback = replacement;
		if (retired != null) retired.close();
	}

	public static inline function abi_version():Int
		return NativeApi.pragtical_hx_abi_version();

	public static inline function init(headless:Bool):Bool
		return NativeApi.pragtical_hx_init(headless);

	public static function shutdown():Void {
		NativeApi.pragtical_hx_plugin_api_install(null);
		var retired = dispatchCallback;
		dispatchCallback = null;
		if (retired != null) retired.close();
		NativeApi.pragtical_hx_shutdown();
	}

	public static inline function last_error():String
		return NativeApi.pragtical_hx_last_error();

	public static inline function window_create(title:String, width:Int, height:Int):Int
		return NativeApi.pragtical_hx_window_create(title, width, height);

	public static inline function window_destroy(window:Int):Bool
		return NativeApi.pragtical_hx_window_destroy(window);

	public static inline function window_valid(window:Int):Bool
		return NativeApi.pragtical_hx_window_valid(window);

	public static inline function window_width(window:Int):Int
		return NativeApi.pragtical_hx_window_width(window);

	public static inline function window_height(window:Int):Int
		return NativeApi.pragtical_hx_window_height(window);

	public static inline function window_display_scale_milli(window:Int):Int
		return NativeApi.pragtical_hx_window_display_scale_milli(window);

	public static inline function text_input_area(window:Int, x:Int, y:Int, width:Int, height:Int, cursor:Int):Bool
		return NativeApi.pragtical_hx_text_input_area(window, x, y, width, height, cursor);

	public static inline function event_poll():Bool
		return NativeApi.pragtical_hx_event_poll();

	public static inline function event_kind():Int
		return NativeApi.pragtical_hx_event_kind();

	public static inline function event_window():Int
		return NativeApi.pragtical_hx_event_window();

	public static inline function event_a():Int
		return NativeApi.pragtical_hx_event_a();

	public static inline function event_b():Int
		return NativeApi.pragtical_hx_event_b();

	public static inline function event_c():Int
		return NativeApi.pragtical_hx_event_c();

	public static inline function event_d():Int
		return NativeApi.pragtical_hx_event_d();

	public static inline function event_text():String
		return NativeApi.pragtical_hx_event_text();

	public static inline function event_push_test(kind:Int, window:Int, a:Int, b:Int):Bool
		return NativeApi.pragtical_hx_event_push_test(kind, window, a, b);

	public static inline function event_push_text_test(kind:Int, window:Int, a:Int, b:Int, text:String):Bool
		return NativeApi.pragtical_hx_event_push_text_test(kind, window, a, b, text);

	public static inline function clipboard_set(text:String):Bool
		return NativeApi.pragtical_hx_clipboard_set(text);

	public static inline function clipboard_get():String
		return NativeApi.pragtical_hx_clipboard_get();

	public static inline function frame_begin(window:Int):Bool
		return NativeApi.pragtical_hx_frame_begin(window);

	public static inline function set_clip_rect(window:Int, x:Int, y:Int, width:Int, height:Int):Bool
		return NativeApi.pragtical_hx_set_clip_rect(window, x, y, width, height);

	public static inline function draw_rect(window:Int, x:Int, y:Int, width:Int, height:Int, rgba:Int):Bool
		return NativeApi.pragtical_hx_draw_rect(window, x, y, width, height, rgba);

	public static inline function font_create(window:Int, path:String, size:Int):Int
		return NativeApi.pragtical_hx_font_create(window, path, size);

	public static inline function font_add_fallback(font:Int, path:String):Bool
		return NativeApi.pragtical_hx_font_add_fallback(font, path);

	public static inline function font_fallback_count(font:Int):Int
		return NativeApi.pragtical_hx_font_fallback_count(font);

	public static inline function font_destroy(font:Int):Bool
		return NativeApi.pragtical_hx_font_destroy(font);

	public static inline function font_height(font:Int):Int
		return NativeApi.pragtical_hx_font_height(font);

	public static inline function font_text_width(font:Int, text:String):Int
		return NativeApi.pragtical_hx_font_text_width(font, text);

	public static inline function draw_text(window:Int, font:Int, x:Int, y:Int, text:String, rgba:Int):Bool
		return NativeApi.pragtical_hx_draw_text(window, font, x, y, text, rgba);

	public static inline function frame_present(window:Int):Bool
		return NativeApi.pragtical_hx_frame_present(window);

	public static inline function frame_count(window:Int):Int
		return NativeApi.pragtical_hx_frame_count(window);

	public static inline function process_create(executable:String, cwd:String):Int
		return NativeApi.pragtical_hx_process_create(executable, cwd);

	public static inline function process_add_argument(process:Int, argument:String):Bool
		return NativeApi.pragtical_hx_process_add_argument(process, argument);

	public static inline function process_set_environment(process:Int, key:String, value:String):Bool
		return NativeApi.pragtical_hx_process_set_environment(process, key, value);

	public static inline function process_start(process:Int):Bool
		return NativeApi.pragtical_hx_process_start(process);

	public static inline function process_write(process:Int, data:String):Int
		return NativeApi.pragtical_hx_process_write(process, data);

	public static inline function process_close_stdin(process:Int):Bool
		return NativeApi.pragtical_hx_process_close_stdin(process);

	public static inline function process_stdout(process:Int):String
		return NativeApi.pragtical_hx_process_stdout(process);

	public static inline function process_stderr(process:Int):String
		return NativeApi.pragtical_hx_process_stderr(process);

	public static inline function process_state(process:Int):Int
		return NativeApi.pragtical_hx_process_state(process);

	public static inline function process_exit_status(process:Int):Int
		return NativeApi.pragtical_hx_process_exit_status(process);

	public static inline function process_cancel(process:Int):Bool
		return NativeApi.pragtical_hx_process_cancel(process);

	public static inline function process_destroy(process:Int):Bool
		return NativeApi.pragtical_hx_process_destroy(process);

	public static function plugin_api_call(operation:Int, token:String, a:String, b:String, c:String):String {
		var callback = dispatchCallback;
		if (callback == null) throw "Pragtical plugin host is not installed";
		var result = NativeApi.pragtical_hx_plugin_api_call(operation, token, a, b, c);
		var error = callback.takeError();
		if (error != null) throw error.toString();
		return result;
	}
}
