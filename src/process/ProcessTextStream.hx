package process;

#if !wasm
import haxe.io.Bytes;
import sys.io.ChildProcess;

/** Keeps an incomplete UTF-8 suffix between nonblocking byte reads. */
class ProcessTextStream {
	final buffer:Bytes = Bytes.alloc(4100);
	var carry:Int = 0;

	public function new() {}

	public function read(child:ChildProcess, standardError:Bool):String {
		var count = standardError ? child.readStderr(buffer, carry, 4096) : child.readStdout(buffer, carry, 4096);
		if (count == -2) return "";
		var total = carry + (count > 0 ? count : 0), complete = 0;
		while (complete < total) {
			var first = buffer.get(complete);
			var width = first < 0x80 ? 1 : first >= 0xC2 && first <= 0xDF ? 2
				: first >= 0xE0 && first <= 0xEF ? 3 : first >= 0xF0 && first <= 0xF4 ? 4 : 1;
			if (complete + width > total && count != -1) break;
			if (complete + width > total) { complete = total; break; }
			var valid = true;
			for (index in 1...width) if ((buffer.get(complete + index) & 0xC0) != 0x80) valid = false;
			complete += valid ? width : 1;
		}
		var result = complete == 0 ? "" : buffer.getString(0, complete);
		carry = total - complete;
		if (carry > 0) buffer.blit(0, buffer, complete, carry);
		return result;
	}
}

#end
