package workspace.client;

/** Small, streaming-safe Markdown block parser. Never interprets HTML or executes code. */
typedef CodexMarkdownBlock = {
  var kind:String;
  var text:String;
  var language:String;
  /** Fence completeness and verbatim body, when this is a code block. */
  @:optional var closed:Null<Bool>;
  @:optional var source:Null<String>;
}

typedef CodexMarkdownInline = {
  var kind:String;
  var text:String;
  var destination:Null<String>;
  @:optional var bold:Null<Bool>;
  @:optional var italic:Null<Bool>;
}

class CodexMarkdown {
  /** Complete image markup, optionally extracted from a prose line. */
  static function imageAt(value:String, start:Int):Null<{block:CodexMarkdownBlock, end:Int}> {
    if (value.substr(start,2) != "![") return null;
    var labelEnd = closing(value, start+1, "[", "]");
    if (labelEnd < 0 || value.charAt(labelEnd+1) != "(") return null;
    var end = closing(value,labelEnd+1,"(",")");
    if (end < 0) return null;
    var target = StringTools.trim(value.substring(labelEnd+2,end));
    if (StringTools.startsWith(target,"<") && StringTools.endsWith(target,">")) target=target.substring(1,target.length-1);
    var webImage = ~/^https?:\/\/[^\s<>]+$/i.match(target);
    var lower = target.toLowerCase();
    var dataImage = dataImageTarget(target,lower);
    if (!webImage && !dataImage && SessionLinkTarget.parse(target) == null) return null;
    return {block:{kind:"image",text:value.substring(start+2,labelEnd),language:target},end:end+1};
  }
  static function dataImageTarget(target:String, lower:String):Bool {
    if (target.length > 5592440 || !(StringTools.startsWith(lower,"data:image/png;base64,")
      || StringTools.startsWith(lower,"data:image/jpeg;base64,") || StringTools.startsWith(lower,"data:image/gif;base64,"))) return false;
    var comma=target.indexOf(","), length=target.length-comma-1;
    if (length == 0 || length % 4 != 0 || length > 5592408) return false;
    var padding=false, paddingCount=0;
    for (index in comma+1...target.length) {
      var ch=target.charAt(index);
      if (ch == "=") { padding=true; paddingCount++; if (paddingCount > 2) return false; }
      else if (padding || "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".indexOf(ch) < 0) return false;
    }
    return true;
  }
  public static function image(value:String):Null<CodexMarkdownBlock> {
    if (value == null) return null;
    var line=StringTools.trim(value), found=imageAt(line,0);
    return found != null && found.end == line.length ? found.block : null;
  }
  /** Recognizes complete inline syntax; unfinished delimiters remain visible. */
  public static function inlineSpans(value:String):Array<CodexMarkdownInline> {
    var spans:Array<CodexMarkdownInline> = [];
    inlineInto(value,spans,false,false,null,0,{remaining:Std.int(Math.min(4*1024*1024,Math.max(4096,value.length*16)))});
    return spans;
  }
  static function inlineInto(value:String,spans:Array<CodexMarkdownInline>,bold:Bool,italic:Bool,destination:Null<String>,depth:Int,budget:{remaining:Int}):Void {
    var plain = new StringBuf(), cursor = 0;
    function flush():Void {
      var text=plain.toString();
      if (text != "") spans.push({kind: destination == null ? "text" : "link", text: text, destination: destination,bold:bold,italic:italic});
      plain = new StringBuf();
    }
    while (cursor < value.length) {
      var character = value.charAt(cursor);
      if (character == "`") {
        var length = 1;
        while (value.charAt(cursor + length) == "`") length++;
        var marker = value.substr(cursor, length), search = cursor + length, end = -1;
        while (search < value.length && budget.remaining>0) {
          var candidate = value.indexOf(marker, search);
          if (candidate < 0) { budget.remaining-=value.length-search; break; }
          budget.remaining-=candidate-search+length;
          if (value.charAt(candidate - 1) != "`" && value.charAt(candidate + length) != "`") { end = candidate; break; }
          search = candidate + length;
        }
        if (end >= 0) {
          flush();
          var body = value.substring(cursor + length, end);
          // CommonMark removes one enclosing space, unless the span is all spaces.
          if (StringTools.startsWith(body, " ") && StringTools.endsWith(body, " ") && StringTools.trim(body) != "")
            body = body.substring(1, body.length - 1);
          spans.push({kind: "code", text: body, destination: destination,bold:bold,italic:italic});
          cursor = end + length;
          continue;
        }
        plain.add(marker); cursor += length; continue;
      } else if (character == "[" && destination == null && (cursor == 0 || value.charAt(cursor - 1) != "!")) {
        var labelEnd = inlineClosing(value, cursor, "[", "]",budget);
        if (labelEnd > cursor + 1 && value.charAt(labelEnd + 1) == "(") {
          var end = inlineClosing(value, labelEnd + 1, "(", ")",budget);
          if (end >= 0) {
            var destination = StringTools.trim(value.substring(labelEnd + 2, end));
            if (StringTools.startsWith(destination, "<") && StringTools.endsWith(destination, ">"))
              destination = destination.substring(1, destination.length - 1);
            if (SessionLinkTarget.external(destination) || SessionLinkTarget.parse(destination) != null) {
              flush();
              inlineInto(value.substring(cursor + 1, labelEnd),spans,bold,italic,destination,depth+1,budget);
              cursor = end + 1;
              continue;
            }
          }
        }
      }
      if ((character == "*" || character == "_") && depth < 12) {
        var count=1; while (value.charAt(cursor+count)==character) count++;
        var width=count>=3 ? 3 : count;
        var next=value.charAt(cursor+width), previous=cursor==0 ? "" : value.charAt(cursor-1);
        var intraword=character=="_" && word(previous) && word(next);
        if (next!="" && !space(next) && !intraword) {
          var end=emphasisEnd(value,cursor+width,character,width,budget);
          if (end>=0) {
            flush();
            inlineInto(value.substring(cursor+width,end),spans,bold || width>=2,italic || width==1 || width==3,destination,depth+1,budget);
            cursor=end+width; continue;
          }
        }
        plain.add(value.substr(cursor,count));cursor+=count;continue;
      }
      if (character == "\\" && "\\`[]()*_".indexOf(value.charAt(cursor + 1)) >= 0 && cursor + 1 < value.length)
        character = value.charAt(++cursor);
      plain.add(character);
      cursor++;
    }
    flush();
  }

  static function space(ch:String):Bool return ch==" " || ch=="\t" || ch=="\n" || ch=="\r";
  static function word(ch:String):Bool return ch!="" && ~/^[A-Za-z0-9]$/.match(ch);
  static function punctuation(ch:String):Bool return ch!="" && "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~".indexOf(ch)>=0;
  static function inlineClosing(value:String,start:Int,open:String,close:String,budget:{remaining:Int}):Int {
    var depth=0,index=start;
    while (index<value.length && budget.remaining>0) {
      budget.remaining--;
      var ch=value.charAt(index);
      if(ch=="\\") {index+=2;continue;}
      if(ch==open) depth++; else if(ch==close && --depth==0) return index;
      index++;
    }
    return -1;
  }
  static function emphasisEnd(value:String,start:Int,marker:String,width:Int,budget:{remaining:Int}):Int {
    var index=start, nested:Array<Int>=[];
    while (index<value.length && budget.remaining>0) {
      budget.remaining--;
      var ch=value.charAt(index);
      if (ch=="\\") {index+=2;continue;}
      if (ch=="[") {
        var labelEnd=inlineClosing(value,index,"[","]",budget);
        if (labelEnd>=0 && value.charAt(labelEnd+1)=="(") {
          var end=inlineClosing(value,labelEnd+1,"(",")",budget);
          if (end>=0) {index=end+1;continue;}
        }
      }
      if (ch=="`") {
        var count=1;while(value.charAt(index+count)=="`") count++;
        var fence=value.substr(index,count), end=value.indexOf(fence,index+count);
        budget.remaining-=end<0 ? value.length-index : end-index+count;
        if (end>=0) {index=end+count;continue;}
      }
      if (ch==marker) {
        var count=1;while(value.charAt(index+count)==marker) count++;
        var before=index>start ? value.charAt(index-1) : "", after=value.charAt(index+count);
        var left=after!="" && !space(after) && (!punctuation(after) || before=="" || space(before) || punctuation(before));
        var right=before!="" && !space(before) && (!punctuation(before) || after=="" || space(after) || punctuation(after));
        if (marker=="_" && word(before) && word(after)) {left=false;right=false;}
        var remaining=count, consumed=0;
        if (right) {
          while (nested.length>0 && remaining>=nested[nested.length-1]) {
            var nestedWidth=nested[nested.length-1];
            // An outer-sized closer can still close the outer delimiter when
            // an inner marker was never completed while streaming.
            if (remaining==width && nestedWidth!=width) break;
            nested.pop();remaining-=nestedWidth;consumed+=nestedWidth;
          }
          if (remaining>=width) return index+consumed+remaining-width;
        }
        if (left && !right && nested.length<12) nested.push(count>=3 ? 3 : count);
        index+=count;continue;
      }
      index++;
    }
    return -1;
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
    var fence = "", language = "", raw = "", proseKind = "";
    function flush():Void {
      if (prose.length > 0) {
        blocks.push({kind: "text", text: prose.join("\n"), language: ""});
        prose = [];
      }
      proseKind = "";
    }
    var sourceLines = value.split("\n"), lineNumber = 0;
    for (sourceLine in sourceLines) {
      var line = StringTools.endsWith(sourceLine, "\r") ? sourceLine.substr(0, sourceLine.length - 1) : sourceLine;
      var ending = lineNumber++ < sourceLines.length - 1 ? "\n" : "";
      var trimmed = StringTools.ltrim(line);
      var indent = line.length - trimmed.length;
      if (fence != "") {
        if (indent <= 3 && StringTools.startsWith(trimmed, fence)
          && StringTools.trim(trimmed.substr(fence.length)).split(fence.charAt(0)).join("") == "") {
          blocks.push({kind: "code", text: code.join("\n"), language: language, closed: true, source: raw});
          fence = ""; code = []; raw = "";
        } else { code.push(line); raw += sourceLine + ending; }
      } else if (indent <= 3 && (StringTools.startsWith(trimmed, "```") || StringTools.startsWith(trimmed, "~~~"))) {
        flush();
        var marker = trimmed.charAt(0), length = 0;
        while (trimmed.charAt(length) == marker) length++;
        fence = trimmed.substr(0, length);
        language = StringTools.trim(trimmed.substr(length)).split(" ")[0].toLowerCase();
      } else if (StringTools.trim(line) == "") flush();
      else {
        var heading = ~/^#{1,6} +/.match(trimmed) && indent <= 3;
        var kind = heading ? "heading" : ~/^> ?/.match(trimmed) && indent <= 3 ? "quote"
          : ~/^(?:[-*+] |[0-9]+[.)] )/.match(trimmed) ? "list" : "paragraph";
        if (prose.length > 0 && (heading || proseKind != kind)) flush();
        proseKind = kind;
        var cursor=0, segment=0, codeMarker=0;
        while (cursor < line.length) {
          var ch=line.charAt(cursor);
          if (ch == "\\") { cursor += 2; continue; }
          if (ch == "`") {
            var run=1; while(line.charAt(cursor+run)=="`") run++;
            if(codeMarker==0) codeMarker=run; else if(codeMarker==run) codeMarker=0;
            cursor+=run; continue;
          }
          var found = codeMarker == 0 && ch == "!" ? imageAt(line,cursor) : null;
          if (found != null) {
            if (cursor > segment) prose.push(line.substring(segment,cursor));
            flush(); blocks.push(found.block); cursor=found.end; segment=cursor;
          } else cursor++;
        }
        if (segment < line.length) prose.push(line.substring(segment));
        if (heading) flush();
      }
    }
    flush();
    // An unfinished fence remains a code block while tokens arrive.
    if (fence != "") blocks.push({kind: "code", text: code.join("\n"), language: language, closed: false, source: raw});
    return blocks;
  }
}
