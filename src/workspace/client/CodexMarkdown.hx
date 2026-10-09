package workspace.client;

/** Small, streaming-safe Markdown block parser. Never interprets HTML or executes code. */
typedef CodexMarkdownBlock = {
  var kind:String;
  var text:String;
  var language:String;
}

typedef CodexMarkdownInline = {
  var kind:String;
  var text:String;
  var destination:Null<String>;
}

class CodexMarkdown {
  /** Recognizes complete inline code and external links; unfinished syntax remains text. */
  public static function inlineSpans(value:String):Array<CodexMarkdownInline> {
    var spans:Array<CodexMarkdownInline> = [], plain = "", cursor = 0;
    function flush():Void {
      if (plain != "") spans.push({kind: "text", text: plain, destination: null});
      plain = "";
    }
    while (cursor < value.length) {
      var character = value.charAt(cursor);
      if (character == "`") {
        var end = value.indexOf("`", cursor + 1);
        if (end >= 0) {
          flush();
          spans.push({kind: "code", text: value.substring(cursor + 1, end), destination: null});
          cursor = end + 1;
          continue;
        }
      } else if (character == "[" && (cursor == 0 || value.charAt(cursor - 1) != "!")) {
        var labelEnd = closing(value, cursor, "[", "]");
        if (labelEnd > cursor + 1 && value.charAt(labelEnd + 1) == "(") {
          var end = closing(value, labelEnd + 1, "(", ")");
          if (end >= 0) {
            var destination = StringTools.trim(value.substring(labelEnd + 2, end));
            if (StringTools.startsWith(destination, "<") && StringTools.endsWith(destination, ">"))
              destination = destination.substring(1, destination.length - 1);
            if (~/^(https?:\/\/|mailto:)[^\s<>]+$/i.match(destination)) {
              flush();
              spans.push({kind: "link", text: value.substring(cursor + 1, labelEnd), destination: destination});
              cursor = end + 1;
              continue;
            }
          }
        }
      }
      if (character == "\\" && "\\`[]()".indexOf(value.charAt(cursor + 1)) >= 0 && cursor + 1 < value.length)
        character = value.charAt(++cursor);
      plain += character;
      cursor++;
    }
    flush();
    return spans;
  }

  static function closing(value:String, start:Int, open:String, close:String):Int {
    var depth = 0, index = start;
    while (index < value.length) {
      if (value.charAt(index) == "\\") {
        index += 2;
        continue;
      }
      if (value.charAt(index) == open) depth++;
      else if (value.charAt(index) == close && --depth == 0) return index;
      index++;
    }
    return -1;
  }

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
