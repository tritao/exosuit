package terminalkit;

/** A rendered grid cell. Empty text means a blank or wide-glyph continuation. */
typedef Cell = {
    final text:String;
    final width:Int;
    final style:haxe.Int64;
}
