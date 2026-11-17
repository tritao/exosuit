package exohost.control;

/**
	An error of Pragtical control protocol v1 (docs/design/exohostctl/TDD-exosuit-ctl.md §2.6): one of its codes
	(`invalid_request`, `unsupported_version`, `invalid_argument`, `not_found`, `ambiguous_target`,
	`permission_denied`, `unsupported`, `busy`, `timeout`, `internal`), a message, and whether trying again may work.
**/
class ControlError {
	public final code:String;
	public final message:String;
	public final retryable:Bool;

	public function new(code:String, message:String, retryable:Bool = false) {
		this.code = code;
		this.message = message;
		this.retryable = retryable;
	}

	public static function internal(message:String):ControlError
		return new ControlError("internal", message);

	public static function retry(code:String, message:String):ControlError
		return new ControlError(code, message, true);

	/** The wire form, `{code, message, retryable}`. */
	public function json():Dynamic
		return {code: code, message: message, retryable: retryable};

	/** An error as a peer sent it; anything malformed is `internal`. */
	public static function read(value:Dynamic):ControlError {
		if (value == null || !Reflect.isObject(value))
			return internal(Std.string(value));
		var code:Dynamic = Reflect.field(value, "code"), message:Dynamic = Reflect.field(value, "message");
		return new ControlError(Std.isOfType(code, String) ? code : "internal", Std.isOfType(message, String) ? message : Std.string(value),
			Reflect.field(value, "retryable") == true);
	}

	/** The exit code `exohostctl` gives this error, Pragtical's (§8.2): 3 for discovery or selection, 4 for a timeout, else 5. */
	public function exitCode():Int
		return switch code {
			case "not_found" | "ambiguous_target": 3;
			case "timeout": 4;
			case "invalid_request" | "unsupported_version": 6;
			default: 5;
		}
}
