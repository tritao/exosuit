		var app:Null<ExosuitApp> = null;
        var report = Sys.getEnv("EXOSUIT_SWITCH_REPORT");
        var reportIndex = 0;
        var pointerUpAt = 0.0;
        var pendingPixelFrame = -1;
        var observedRoot:Null<haxeon.ui.core.RenderNode> = null;
        host.onFrameRendered = function() {
            if (app == null || report == null) return;
            var at = Sys.time();
            var nodes:Array<Dynamic> = [];
            var root = app.context().root;
            if (root != null && root != observedRoot) {
                observedRoot = root;
                root.on(haxeon.ui.core.UiEventKind.PointerUp, function(_) pointerUpAt = Sys.time(), "capture");
            }
            if (root != null) root.walk(function(node) {
                if (node.resolved == null) return;
                var b = node.globalBounds();
                if (b.width > 0 && b.height > 0) nodes.push({key:node.styleKey,
                    label:node.semantics == null ? null : node.semantics.label,
                    x:b.x,y:b.y,width:b.width,height:b.height});
            });
            var line = haxe.Json.stringify({index:reportIndex++,at:at,pointerUpAt:pointerUpAt,
                renderedTerminalRows: {
                    var tab = app.host.activeTab();
                    var terminal = tab == null ? null : ui.UiEditorTabs.terminal(tab);
                    terminal == null || !Std.isOfType(terminal.panel,ui.TerminalPane) ? []
                        : [for (row in cast(terminal.panel,ui.TerminalPane).renderedRows) row.text];
                }, state:app.diagnosticState(),nodes:nodes});
            sys.io.File.saveContent(report + "/" + (reportIndex-1) + ".json", line);
            if (Sys.getEnv("EXOSUIT_SWITCH_PIXELS") == "1")
                pendingPixelFrame = reportIndex-1;
        };
