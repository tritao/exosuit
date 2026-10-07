package search;

/** Bounded literal matching for workspace services that do not depend on editor documents. */
class LiteralSearch {
  public static function findTextLimited(text:String,
    query:String, caseSensitive:Bool, maxMatches:Int):Array < LiteralMatch > {
    var result:Array<LiteralMatch> = [];
    if (text == null || query == null || query.length == 0 || maxMatches <= 0) return result;
    var needle = caseSensitive ? query : query.toLowerCase(), lineStart = 0, lineIndex = 0;
    while (result.length < maxMatches && lineStart <= text.length) {
      var lineEnd = text.indexOf("\n", lineStart);
      if (lineEnd < 0) lineEnd = text.length;
      var line = text.substring(lineStart, lineEnd), haystack = caseSensitive ? line : line.toLowerCase(), from = 0;
      while (result.length < maxMatches && from <= haystack.length - needle.length) {
        var column = haystack.indexOf(needle, from);
        if (column < 0) break;
        result.push(new LiteralMatch(lineIndex, column, query.length, line));
        from = column + needle.length;
      }
      if (lineEnd == text.length) break;
      lineStart = lineEnd + 1;
      lineIndex++;
    }
    return result;
  }
}
