package app;

import haxeon.ui.FontCollection;
import probes.BuildWriteProbe;
import probes.DeferredFocusProbe;
import probes.InteractionProbe;
import probes.Report;
import probes.ReuseFrameProbe;
import probes.StateReadyProbe;
import probes.TextFieldTickProbe;
import probes.TrackedScopeProbe;
import probes.TreeExpansionProbe;

/**
	Headless probes of the haxeon UI behaviours the Exosuit port relies on (.port/docs/C-port-plan.md section 5). Each
	line states a rule and what this run observed; exit 1 when a rule no longer holds.
**/
class PortProbesMain {
	static function main():Int {
		var fonts = FontCollection.create();
		fonts.addSystemFallbacks();
		TextFieldTickProbe.run(fonts);
		DeferredFocusProbe.run(fonts);
		TreeExpansionProbe.run(fonts);
		StateReadyProbe.run(fonts);
		BuildWriteProbe.run(fonts);
		TrackedScopeProbe.run(fonts);
		InteractionProbe.run(fonts);
		ReuseFrameProbe.run(fonts);
		fonts.dispose();
		Sys.println(Report.failures == 0 ? "PASS: port probes" : "FAIL: " + Report.failures + " port probe rules");
		return Report.failures == 0 ? 0 : 1;
	}
}
