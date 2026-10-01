package platform;

/** Immutable host policy shared by controllers and command surfaces. */
class HostCapabilities {
	final enabled:Array<HostCapability>;

	public function new(enabled:Array<HostCapability>)
		this.enabled = enabled.copy();

	public function supports(capability:HostCapability):Bool {
		if (enabled.indexOf(capability) < 0) return false;
		return switch capability {
			case LanguageServices: enabled.indexOf(Processes) >= 0;
			case SourcePlugins: enabled.indexOf(Threads) >= 0;
			default: true;
		};
	}

	public static function desktop():HostCapabilities
		return new HostCapabilities([Clipboard, Filesystem, Processes, Threads, LanguageServices, SourcePlugins]);

	/** Browser files are session-local; native process/thread services are absent. */
	public static function browser(clipboard:Bool = false, url:Bool = true):HostCapabilities {
		var enabled:Array<HostCapability> = [Filesystem];
		if (clipboard) enabled.push(Clipboard);
		if (url) enabled.push(Url);
		return new HostCapabilities(enabled);
	}
}
