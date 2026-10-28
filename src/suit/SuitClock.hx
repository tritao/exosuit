package suit;

/**
	The one clock and the one ordering rule behind suit's ownership links.

	Every registry writer stamps records with `now()`. HashLink's `Date.now()` is truncated to whole seconds,
	which would put a record written in the same second its process started before that start.
**/
class SuitClock {
	/**
		Records from builds before version 2 were stamped with `Date.now()`: whole seconds, up to 1 s early.
		Only those get this allowance.
	**/
	public static inline var WHOLE_SECOND_ALLOWANCE_MS:Float = 1000;

	/** Milliseconds since the Unix epoch, with sub-millisecond resolution. */
	public static function now():Float
		return Sys.time() * 1000;

	/**
		`earlier` started no later than `later`. A child never starts before its parent, and a process starts
		before it registers, so a link that breaks this belongs to a reused pid. Unknown times (0 or less)
		prove nothing and never link.
	**/
	public static function startedBefore(earlier:Float, later:Float):Bool
		return earlier > 0 && later > 0 && earlier <= later;

	/** True when a process that started at `started` can have written a record stamped `registeredAt` by a writer of `version`. */
	public static function registeredAfterStart(started:Float, registeredAt:Float, version:Int):Bool
		return startedBefore(started, version < 2 ? registeredAt + WHOLE_SECOND_ALLOWANCE_MS : registeredAt);
}
