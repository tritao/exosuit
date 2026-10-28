package scm;

/** An operation limited to a source's folders, or why it was refused (see LocalScmSource.narrowOperation). */
enum NarrowedOperation {
	Allowed(operation:ScmOperation);
	Refused(reason:String);
}
