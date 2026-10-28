package scm;

/** Only public github.com repository URLs are permitted as browser destinations. */
class GithubRemote {
	public static function repository(value:String):Null<String> {
		if (value == null || value != StringTools.trim(value) || value.length > 512) return null;
		var pattern = ~/^(?:https:\/\/github\.com\/|ssh:\/\/git@github\.com\/|git@github\.com:)([A-Za-z0-9](?:[A-Za-z0-9-]{0,38}))\/([A-Za-z0-9._-]+?)(?:\.git)?$/i;
		if (!pattern.match(value)) return null;
		var owner = pattern.matched(1), repo = pattern.matched(2);
		if (repo == "." || repo == ".." || owner.indexOf("--") >= 0 || StringTools.endsWith(owner, "-")) return null;
		return "https://github.com/" + owner + "/" + repo;
	}
	public static function pullRequestPage(repository:String, branch:String):Null<String> {
		var canonical = GithubRemote.repository(repository);
		if (canonical == null || branch == null || branch.length == 0 || branch.length > 255 || ~/[\x00-\x20\x7f]/.match(branch)) return null;
		var encoded = new StringBuf(), bytes = haxe.io.Bytes.ofString(branch), hex = "0123456789ABCDEF";
		for (index in 0...bytes.length) {
			var b = bytes.get(index);
			if (b >= 65 && b <= 90 || b >= 97 && b <= 122 || b >= 48 && b <= 57 || b == 45 || b == 46 || b == 95 || b == 126)
				encoded.addChar(b);
			else { encoded.add("%"); encoded.add(hex.charAt(b >> 4)); encoded.add(hex.charAt(b & 15)); }
		}
		return canonical + "/compare/" + encoded.toString() + "?expand=1";
	}
}
