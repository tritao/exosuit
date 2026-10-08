package workspace.client;

/** Small, streaming-safe Markdown block parser. Never interprets HTML or executes code. */
typedef CodexMarkdownBlock = {
  var kind:String;
  var text:String;
  var language:String;
}

class CodexMarkdown {
  public static function parse(value:String):Array<CodexMarkdownBlock> {
    var blocks:Array<CodexMarkdownBlock> = [];
    var prose:Array<String> = [], code:Array<String> = [];
    var fence = "", language = "";
    function flush():Void {
      if (prose.length > 0) {
        blocks.push({kind: "text", text: prose.join("\n"), language: ""});
        prose = [];
      }
    }
    for (line in StringTools.replace(value, "\r\n", "\n").split("\n")) {
      var trimmed = StringTools.ltrim(line);
      var indent = line.length - trimmed.length;
      if (fence != "") {
        if (indent <= 3 && StringTools.startsWith(trimmed, fence)
          && StringTools.trim(trimmed.substr(fence.length)).split(fence.charAt(0)).join("") == "") {
          blocks.push({kind: "code", text: code.join("\n"), language: language});
          fence = ""; code = [];
        } else code.push(line);
      } else if (indent <= 3 && (StringTools.startsWith(trimmed, "```") || StringTools.startsWith(trimmed, "~~~"))) {
        flush();
        var marker = trimmed.charAt(0), length = 0;
        while (trimmed.charAt(length) == marker) length++;
        fence = trimmed.substr(0, length);
        language = StringTools.trim(trimmed.substr(length)).split(" ")[0].toLowerCase();
      } else if (StringTools.trim(line) == "") flush();
      else prose.push(line);
    }
    flush();
    // An unfinished fence remains a code block while tokens arrive.
    if (fence != "") blocks.push({kind: "code", text: code.join("\n"), language: language});
    return blocks;
  }
}
