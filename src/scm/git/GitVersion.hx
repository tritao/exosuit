package scm.git;

class GitVersion {
	public final major:Int;
	public final minor:Int;
	public final patch:Int;

	public function new(major:Int, minor:Int, patch:Int = 0) {
		this.major = major;
		this.minor = minor;
		this.patch = patch;
	}

	public function supportsScm():Bool return major > 2 || (major == 2 && minor >= 25);

	public function toString():String return '$major.$minor.$patch';

	public static function parse(output:String):Null<GitVersion> {
		var pattern = ~/\bgit version ([0-9]+)\.([0-9]+)(?:\.([0-9]+))?/;
		if (!pattern.match(output)) return null;
		var major = Std.parseInt(pattern.matched(1)), minor = Std.parseInt(pattern.matched(2)), patch = Std.parseInt(pattern.matched(3));
		return major == null || minor == null ? null : new GitVersion(major, minor, patch == null ? 0 : patch);
	}
}
