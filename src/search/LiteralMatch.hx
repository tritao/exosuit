package search;

/** A literal text match with UTF-16 string offsets, independent of editor state. */
class LiteralMatch {
  public final line:Int;
  public final column:Int;
  public final length:Int;
  public final lineText:String;

  public function new(line:Int, column:Int, length:Int, lineText:String) {
    this.line = line;
    this.column = column;
    this.length = length;
    this.lineText = lineText;
  }
}
