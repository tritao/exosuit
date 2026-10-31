package ui;

/** Where on a row a drop lands: before it, after it (between siblings), or onto it (into a group, or the workspace root). */
enum WorkbenchDropZone {
	Before;
	Into;
	After;
}
