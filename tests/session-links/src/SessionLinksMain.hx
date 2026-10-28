import workspace.client.SessionLinkTarget;
import workspace.client.CodexMarkdown;

class SessionLinksMain {
  static function require(value:Bool, message:String):Void { if (!value) throw message; }
  static function main():Void {
    for (value in ["javascript:alert(1)", "file:///etc/passwd", "data:text/html,hi", "command:run", "//server/share", "\\\\server\\share", "#anchor", "src/a.hx\n"])
      require(SessionLinkTarget.parse(value) == null, "Accepted invalid link: " + value);
    for (value in ["https://example.com/a_(b)?x=1", "http://localhost:3000", "mailto:hello@example.com"])
      require(SessionLinkTarget.external(value) && SessionLinkTarget.parse(value) == null, "External classification: " + value);
    var target = SessionLinkTarget.parse("src/Main.hx:42:7");
    require(SessionLinkTarget.parse("Justfile").resolve("/repo") == "/repo/Justfile", "Rejected an extensionless file");
    require(SessionLinkTarget.relativeWithin("/repo", "/repository/a.hx") == null, "Containment prefix collision");
    require(SessionLinkTarget.relativeWithin("/repo", "/Repo/a.hx") == null, "Remote POSIX case changed");
    require(SessionLinkTarget.relativeWithin("C:/Repo", "c:/repo/a.hx") == "a.hx", "Remote drive case handling");
    require(workspace.client.SessionImageActivity.target("/repo","/repo/project","../assets/image.png")=="/repo/assets/image.png",
      "Workspace image path did not resolve against session cwd");
    require(workspace.client.SessionImageActivity.target("C:/Repo","C:/Repo/project","..\\images\\icon.png")=="C:/Repo/images/icon.png",
      "Native Windows image path did not resolve inside the workspace");
    require(workspace.client.SessionImageActivity.target("C:/Repo","C:/Repo/project","D:\\other\\image.png")==null,
      "Native image crossed a drive boundary");
    for (path in ["../../secret.png", "/elsewhere/image.png", "https://example.com/image.png", "image.png:12", "image.png#L1", "//server/file.png"])
      require(workspace.client.SessionImageActivity.target("/repo","/repo/project",path)==null,"Unsafe native image path was accepted: "+path);
    require(target != null && target.line == 41 && target.column == 6 && target.resolve("C:\\repo") == "C:/repo/src/Main.hx", "Windows relative location");
    target = SessionLinkTarget.parse("C:\\repo\\src\\Main.hx:12");
    require(target != null && target.line == 11 && target.resolve("/other") == "C:/repo/src/Main.hx", "Drive path location");
    target = SessionLinkTarget.parse("../README.md#L3-L8");
    require(target != null && target.line == 2 && target.resolve("/repo/src") == "/repo/README.md", "POSIX relative range");
    target = SessionLinkTarget.parse("/repo/a b.svg#L2C4");
    require(target != null && target.line == 1 && target.column == 3 && target.resolve("/other") == "/repo/a b.svg", "Space-containing artifact location");
    var spans = CodexMarkdown.inlineSpans("[source](src/Main.hx:4) and [docs](https://example.com/a_(b))");
    require(spans.length == 3 && spans[0].kind == "link" && spans[2].kind == "link", "Explicit links");
    for (value in ["[unsafe](javascript:alert(1))", "`[literal](src/a.hx)`", "[unfinished](src/a.hx"])
      for (span in CodexMarkdown.inlineSpans(value)) require(span.kind != "link", "Unsafe/unfinished links became active");
    var styled=CodexMarkdown.inlineSpans("**bold *nested*** and ***both***");
    require(styled.length==4 && styled[0].text=="bold " && styled[0].bold==true && styled[0].italic!=true
      && styled[1].text=="nested" && styled[1].bold==true && styled[1].italic==true
      && styled[3].text=="both" && styled[3].bold==true && styled[3].italic==true,"Nested emphasis styles");
    styled=CodexMarkdown.inlineSpans("*[**docs** and `code`](https://example.com/a*b)*");
    require(styled.length==3 && styled[0].kind=="link" && styled[0].bold==true && styled[0].italic==true
      && styled[2].kind=="code" && styled[2].italic==true && styled[2].destination=="https://example.com/a*b",
      "Styled link and code lost content or destination");
    styled=CodexMarkdown.inlineSpans("\\*literal\\* and **unfinished and snake_case");
    require(styled.length==1 && styled[0].text=="*literal* and **unfinished and snake_case" && styled[0].bold!=true,
      "Escaped or unfinished emphasis was consumed");
    styled=CodexMarkdown.inlineSpans("*outer **inner***");
    require(styled.length==2 && styled[0].italic==true && styled[1].italic==true && styled[1].bold==true,
      "Nested strong inside emphasis failed");
    styled=CodexMarkdown.inlineSpans("*italic **bold** italic*");
    require(styled.length==3 && styled[0].text=="italic " && styled[0].italic==true && styled[0].bold!=true
      && styled[1].text=="bold" && styled[1].bold==true && styled[1].italic==true
      && styled[2].text==" italic" && styled[2].italic==true && styled[2].bold!=true,"Inner strong closed outer emphasis");
    styled=CodexMarkdown.inlineSpans("**bold *italic* bold**");
    require(styled.length==3 && styled[0].bold==true && styled[1].bold==true && styled[1].italic==true
      && styled[2].text==" bold" && styled[2].bold==true && styled[2].italic!=true,"Inner emphasis closed outer strong");
    styled=CodexMarkdown.inlineSpans("(*emphasis*), **bold!** and *unfinished");
    require(styled.length==5 && styled[1].text=="emphasis" && styled[1].italic==true
      && styled[3].text=="bold!" && styled[3].bold==true && styled[4].text==" and *unfinished",
      "Punctuation or incomplete delimiter changed");
    var malformed=""; for (_ in 0...19) malformed=malformed=="" ? "[" : malformed+malformed;
    styled=CodexMarkdown.inlineSpans(malformed);
    require(styled.length==1 && styled[0].text==malformed,"Long malformed input lost literal source");
    var blocks = CodexMarkdown.parse("Before\r\n\r\n````svg\r\n<svg>```</svg>\r\n````\r\nAfter");
    require(blocks.length == 3 && blocks[1].kind == "code" && blocks[1].text == "<svg>```</svg>", "Source fidelity");
    var stream = CodexMarkdown.parse("~~~html\n<script>literal</script>");
    require(stream.length == 1 && stream[0].kind == "code" && stream[0].text == "<script>literal</script>", "Unfinished fence fidelity");
    var invalidHunk = workspace.client.SessionDiff.parse("@@ -0,0 +1,2 @@\n-unattributed\n+first\n+second")[0].lines;
    require(invalidHunk[1].kind == "meta" && invalidHunk[1].oldLine == -1,
      "Malformed hunk invented removed-line attribution");
    require(invalidHunk[2].newLine == 1 && invalidHunk[3].newLine == 2,
      "Malformed row corrupted subsequent valid hunk counters");
    trace("PASS: session link targets, locations, schemes, streaming, source fidelity and hunk bounds");
  }
}
