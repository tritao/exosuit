package ui;

/** Whether a group can be removed now, and if not, why. */
enum GroupRemoval {
	Allowed;
	/** The service does not grant removing groups. */
	NotPermitted;
	/** Another workspace operation is running, or the catalogs are still loading. */
	Busy;
	/** It holds groups, terminals or agent sessions. */
	NotEmpty;
}
