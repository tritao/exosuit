package plugin;

/** Semantic edit-state marker painted beside one or more editor lines. */
enum PluginGutterMarkerKind {
	Added;
	Modified;
	DeletedAbove;
	DeletedBelow;
}
