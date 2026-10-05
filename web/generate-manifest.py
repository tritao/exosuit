#!/usr/bin/env python3
"""Select the browser application graph without desktop-only implementations."""
import json
from pathlib import Path

root = Path(__file__).resolve().parents[1]
excluded = {"NativeDesktopServices.hx", "ui/TerminalPane.hx", "plugin/DynamicPlugin.hx",
            "plugin/DynamicHostRouter.hx", "plugin/DynamicHostRegistration.hx",
            "plugin/DynamicCompileCompletion.hx", "plugin/NativeSourcePluginLoader.hx"}
sources = ["src/app/WebMain.hx"]
for directory in ("src", "graphical/src"):
    for source in sorted((root / directory).rglob("*.hx")):
        relative = source.relative_to(root / directory).as_posix()
        if relative.startswith("app/") or relative in excluded:
            continue
        sources.append("../" + source.relative_to(root).as_posix())
manifest = {
    "version": 1, "package": {"name": "exosuit-web"}, "entry": "app.WebMain",
    "sourceRoots": ["src", "../src", "../graphical/src"],
    "scopeSourceRoots": False, "sources": sources,
    "workspace": ["../haxeon/packages/platform", "../haxeon/packages/gpu"],
    "dependencies": {
        "haxeon-platform": {"path": "../haxeon/packages/platform"},
        "haxeon-ui": {"path": "../haxeon/packages/ui"},
        "editorkit": {"path": "../../editorkit"},
    },
    "ffi": {"interfaces": ["../bindings/pragtical_hx.hxi"],
            "projections": ["../bindings/pragtical_hx.hxmap"]},
    "target": "wasm32", "outputDir": "build"
}
(root / "web/haxeon.json").write_text(json.dumps(manifest, indent=2) + "\n")
