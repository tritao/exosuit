package textmateregex;

import haxe.io.Bytes;
import textmateregex.ffi.TextMateRegex;
import textmateregex.ffi.TextMateRegexTypes.Scanner;

/** Managed UTF-8/UTF-16 adapter for the Oniguruma TextMate scanner. */
class RegexScanner {
	var handle:Null<Scanner>;
	var patternCount = 0;

	public function new() {
		var created = TextMateRegex.textmate_regex_scanner_create();
		if (created.status != 0 || created.out_scanner == null)
			throw 'Could not create TextMate regex scanner: ${TextMateRegex.textmate_regex_last_error()} (${created.status})';
		handle = created.out_scanner;
	}

	public function add(pattern:String):Int {
		var live = requireLive(), bytes = Bytes.ofString(pattern);
		var status = TextMateRegex.textmate_regex_scanner_add(live, bytes);
		if (status != 0) throw 'Could not compile TextMate regex "$pattern": ${TextMateRegex.textmate_regex_last_error()} ($status)';
		return patternCount++;
	}

	public function find(text:String, startUtf16:Int = 0):Null<RegexMatch> {
		return findInput(new RegexInput(text), startUtf16);
	}

	/** Searches a shared line snapshot without rebuilding its UTF-8 offset map. */
	public function findInput(input:RegexInput, startUtf16:Int = 0):Null<RegexMatch> {
		if (input == null) throw "TextMate regex input is null";
		var live = requireLive(), startByte = input.byteOffset(startUtf16);
		var pattern = TextMateRegex.textmate_regex_scanner_search(live, input.bytes, startByte);
		if (pattern == -1) return null;
		if (pattern < 0) throw 'TextMate regex search failed: ${TextMateRegex.textmate_regex_last_error()} ($pattern)';
		var firstByte = TextMateRegex.textmate_regex_scanner_match_start(live);
		var lastByte = TextMateRegex.textmate_regex_scanner_match_end(live);
		if (firstByte < 0 || lastByte < firstByte || lastByte > input.bytes.length)
			throw "Oniguruma returned invalid match offsets";
		var captureCount = TextMateRegex.textmate_regex_scanner_capture_count(live, pattern);
		if (captureCount < 0 || captureCount > 256) throw "Oniguruma returned an invalid capture count";
		var captures:Array<RegexCapture> = [];
		for (index in 0...captureCount) {
			var first = TextMateRegex.textmate_regex_scanner_capture_start(live, pattern, index);
			var last = TextMateRegex.textmate_regex_scanner_capture_end(live, pattern, index);
			captures.push(first < 0 || last < first ? new RegexCapture(-1, -1) :
				new RegexCapture(input.utf16Offset(first), input.utf16Offset(last)));
		}
		return new RegexMatch(pattern, input.utf16Offset(firstByte), input.utf16Offset(lastByte), captures);
	}

	public function close():Void {
		if (handle == null) return;
		TextMateRegex.textmate_regex_scanner_free(handle);
		handle = null;
	}

	function requireLive():Scanner {
		if (handle == null) throw "TextMate regex scanner is closed";
		return handle;
	}

}
