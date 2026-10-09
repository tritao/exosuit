package ui;

class FileSizeLabel {
	public static function format(bytes:Int):String {
		if (bytes < 1024) return bytes + " B";
		var value = bytes / 1024.0, unit = " KB";
		if (value >= 1024) { value /= 1024; unit = " MB"; }
		var rounded = Math.round(value * 100);
		return Std.int(rounded / 100) + "." + StringTools.lpad(Std.string(rounded % 100), "0", 2) + unit;
	}
}
