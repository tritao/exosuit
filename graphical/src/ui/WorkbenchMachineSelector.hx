package ui;

import haxeon.ui.Insets;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.View;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.controls.Select;
import haxeon.ui.widgets.controls.SelectOption;
import haxeon.ui.widgets.layout.Column;

/**
	Above the Workbench tree, with suit on: the machine whose workspaces the tree shows. Today the list holds this
	machine only; remote machines join it later, each as another option.
**/
class WorkbenchMachineSelector implements View {
	/** This machine's option value. */
	public static inline final THIS_MACHINE = "this";
	final view:WorkbenchMachineView;
	final choose:String->Void;

	public function new(view:WorkbenchMachineView, choose:String->Void) {
		this.view = view; this.choose = choose;
	}

	/** The machines to choose from, this machine first: "cube · this machine" once suit has answered. */
	public static function choices(view:WorkbenchMachineView):Array<SelectOption<String>> {
		var state = view.machine;
		return [new SelectOption(THIS_MACHINE, state == null ? "This machine" : state.name + " · this machine", THIS_MACHINE)];
	}

	public function build(context:BuildContext):RenderNode {
		var pickerStyle = new LayoutStyle(); pickerStyle.width = LayoutAxis.stretch(); pickerStyle.height = LayoutAxis.fixed(30);
		var picker = new Select("workbench-machine", choices(view), THIS_MACHINE, choose, pickerStyle);
		picker.accessibilityLabel = "Machine";
		var style = new LayoutStyle(); style.width = LayoutAxis.stretch(); style.padding = new Insets(4, 4, 4, 2);
		return new Column("workbench-machine-selector", [new KeyedView("picker", picker)], style).build(context);
	}
}
