#!/usr/bin/env python3
"""Select the browser application graph without desktop-only implementations."""
import json
from pathlib import Path

root = Path(__file__).resolve().parents[1]
excluded = {"NativeDesktopServices.hx", "plugin/DynamicPlugin.hx",
            "plugin/DynamicHostRouter.hx", "plugin/DynamicHostRegistration.hx",
            "plugin/DynamicCompileCompletion.hx", "plugin/NativeSourcePluginLoader.hx"}
sources = ["src/app/WebMain.hx"]
for directory in ("src", "graphical/src"):
    for source in sorted((root / directory).rglob("*.hx")):
        relative = source.relative_to(root / directory).as_posix()
        if relative.startswith("app/") or relative in excluded:
            continue
        sources.append("../" + source.relative_to(root).as_posix())
# LanguageServerCommand resolves the checkout's VM through Haxeon's HashLinkPath, which lives with the compiler's sources.
sources += ["../haxeon/src/build/HashLinkPath.hx", "../haxeon/src/compiler/core/InternalError.hx"]
manifest = {
    "version": 1, "package": {"name": "exosuit-web"}, "entry": "app.WebMain",
    "sourceRoots": ["src", "../src", "../graphical/src", "../haxeon/src"],
    "scopeSourceRoots": False, "sources": sources,
    "dependencies": {
        "haxeon-platform": {"path": "../haxeon/packages/platform"},
        "haxeon-ui": {"path": "../haxeon/packages/ui"},
        "haxeon-editor": {"path": "../haxeon/packages/editor"},
        "noisekit": {"path": "../native-packages/noise"},
        "terminalkit": {"path": "../native-packages/terminal"},
        "terminalsession": {"path": "../native-packages/terminal/session"},
        "textmateregex": {"path": "../native-packages/oniguruma"},
    },
    "target": "wasm32", "outputDir": "build"
}
(root / "web/haxeon.json").write_text(json.dumps(manifest, indent=2) + "\n")
