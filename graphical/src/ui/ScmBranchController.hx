package ui;

import scm.ScmSource;

/** Owns branch picker requests, cancellation and branch operation feedback. */
class ScmBranchController {
	final host:UiWorkbenchHost;
	final sourceControlSource:Void->Null<ScmSource>;
	/** Whether branches can be switched in a repository through a source (null: the panel's). */
	final canCheckoutScmRepository:(Null<scm.ScmRepository>, Null<ScmSource>)->Bool;
	final activateSidebarDestination:String->Void;
	final requestFrame:Void->Void;
	final reportError:String->Void;
	final nextOperationId:Void->String;
	var scmBranchJob:Null<scm.ScmJob<Array<scm.ScmBranch>>>;
	var scmBranchRequestToken:Int = 0;

	public function new(host:UiWorkbenchHost, sourceControlSource:Void->Null<ScmSource>,
			canCheckoutScmRepository:(Null<scm.ScmRepository>, Null<ScmSource>)->Bool, activateSidebarDestination:String->Void,
			requestFrame:Void->Void, reportError:String->Void, nextOperationId:Void->String) {
		this.host = host;
		this.sourceControlSource = sourceControlSource;
		this.canCheckoutScmRepository = canCheckoutScmRepository;
		this.activateSidebarDestination = activateSidebarDestination;
		this.requestFrame = requestFrame;
		this.reportError = reportError;
		this.nextOperationId = nextOperationId;
	}

	/**
		Whether a request through `source` still stands. A request through the panel's source lapses when that source
		changes; one through a pinned source (a session's, see open) lasts while it is connected, and its `scopeValid`
		decides the rest.
	**/
	function isScmSourceActive(identity:String, ?pinned:ScmSource):Bool {
		if (pinned != null) return pinned.connected() && pinned.identity() == identity;
		var source = sourceControlSource();
		return source != null && source.identity() == identity;
	}

	public function cancel():Void {
		scmBranchRequestToken++;
		if (scmBranchJob != null) scmBranchJob.cancel();
		scmBranchJob = null;
	}

	function showUnavailable(reason:String, label:String = "Branch switching unavailable"):Void {
		cancel();
		var entry = new commandview.CommandViewEntry(label, reason, "@unavailable");
		entry.enabled = false;
		host.openCommandView(new commandview.CommandViewProvider("Switch Branch: ", [entry], function(_) {}, function(_, _, _) {}, function() cancel()));
		requestFrame();
	}

	/**
		Shows the branches of `repository` (the source's first when null). `through` pins the source the picker reads and
		acts through, instead of the panel's (an Agent session's own source); `scopeValid` then guards the request.
	**/
	public function open(repository:Null<scm.ScmRepository>, ?scopeValid:Void->Bool, ?through:ScmSource):Void {
		if (scopeValid != null && !scopeValid()) return;
		var source = through != null ? through : sourceControlSource();
		if (source == null) { showUnavailable("No source control repository is available."); return; }
		var target = repository;
		if (target == null) {
			var repositories = source.repositories();
			target = repositories.length == 0 ? null : repositories[0];
		}
		if (target == null) { showUnavailable("Repository discovery is still in progress."); return; }
		if (!source.connected()) { showUnavailable("Reconnect the workspace to switch branches."); return; }
		var error = source.error(target.id);
		if (!canCheckoutScmRepository(target, through)) {
			var features = source.features(target.id);
			showUnavailable(error != null ? error.message : !target.trusted ? "Trust this repository before switching branches." :
				features == null ? "Repository capabilities are still loading." : !features.branches ? "This source control provider does not support branch switching." :
				"Branch switching is unavailable with the current repository permissions.");
			return;
		}
		var selectedRepository:scm.ScmRepository = cast target;
		showUnavailable("Reading repository branches.", "Loading branches…");
		var token = scmBranchRequestToken;
		var identity = source.identity();
		requestFrame();
		var job = source.branches(selectedRepository.id, function(result) {
			if (token != scmBranchRequestToken || !isScmSourceActive(identity, through)) return;
			scmBranchJob = null;
			if (scopeValid != null && !scopeValid()) { host.closeCommandView(); return; }
			if (result.error != null) {
				showUnavailable(result.error.message);
				requestFrame();
				return;
			}
			showBranches(source, selectedRepository, result.value == null ? [] : result.value, scopeValid, through);
		});
		if (!job.complete && !job.cancelled) scmBranchJob = job;
	}

	function showBranches(source:ScmSource, repository:scm.ScmRepository, branches:Array<scm.ScmBranch>, ?scopeValid:Void->Bool,
			?through:ScmSource):Void {
		var entries:Array<commandview.CommandViewEntry> = [
			new commandview.CommandViewEntry("Create Branch…", "Create a branch from the current HEAD", "@create", null,
				"create branch new", "Actions"),
			new commandview.CommandViewEntry("Open Source Control", "Show repository changes", "@source-control", null,
				"open changes repository source control", "Actions")
		];
		for (branch in branches) {
			var section = branch.remote ? "Remote Branches" : "Local Branches";
			var detail = branch.current ? "Current branch" : branch.remote ? "Remote branch" : "Local branch";
			entries.push(new commandview.CommandViewEntry(branch.name, detail, branch.reference, null,
				branch.name + " " + branch.reference + " " + detail, section));
		}
		var valid = function() return (scopeValid == null || scopeValid()) && isScmSourceActive(source.identity(), through)
			&& canCheckoutScmRepository(repository, through);
		host.openCommandView(new commandview.CommandViewProvider("Switch Branch: ", entries, function(_) {}, function(entry, _, _) {
			if (!valid()) { host.closeCommandView(); return; }
			host.closeCommandView();
			if (entry == null) return;
			if (entry.value == "@create") createPrompt(repository, scopeValid, through);
			else if (entry.value == "@source-control") activateSidebarDestination("scm");
			else checkout(source, repository, entry.value, scopeValid, through);
		}, function() cancel()));
	}

	public function createPrompt(repository:Null<scm.ScmRepository>, ?scopeValid:Void->Bool, ?through:ScmSource):Void {
		if (scopeValid != null && !scopeValid()) return;
		var source = through != null ? through : sourceControlSource();
		if (source == null) return;
		var target = repository;
		if (target == null) {
			var repositories = source.repositories();
			target = repositories.length == 0 ? null : repositories[0];
		}
		if (target == null || !canCheckoutScmRepository(target, through)) return;
		var selectedRepository:scm.ScmRepository = cast target;
		var identity = source.identity();
		var selected = selectedRepository;
		host.openCommandView(new commandview.CommandViewProvider("New Branch: ", [], function(_) {}, function(_, name, _) {
			host.closeCommandView();
			if (!isScmSourceActive(identity, through) || (scopeValid != null && !scopeValid())) return;
			create(source, selected, name, scopeValid, through);
		}, function() {}));
	}

	function checkout(source:ScmSource, repository:scm.ScmRepository, reference:String, ?scopeValid:Void->Bool, ?through:ScmSource):Void {
		apply(source, repository, scm.ScmOperation.Checkout(reference), "Switched branch", scopeValid, through);
	}

	function create(source:ScmSource, repository:scm.ScmRepository, name:String, ?scopeValid:Void->Bool, ?through:ScmSource):Void {
		var branch = StringTools.trim(name);
		if (branch.length == 0) {
			reportError("Enter a branch name");
			return;
		}
		apply(source, repository, scm.ScmOperation.CreateBranch(branch), "Created branch " + branch, scopeValid, through);
	}

	function apply(source:ScmSource, repository:scm.ScmRepository, operation:scm.ScmOperation, label:String, ?scopeValid:Void->Bool,
			?through:ScmSource):Void {
		if ((scopeValid != null && !scopeValid()) || !isScmSourceActive(source.identity(), through)
			|| !canCheckoutScmRepository(repository, through)) return;
		var snapshot = source.snapshot(repository.id);
		if (snapshot == null) {
			reportError("Refresh the repository before changing branches");
			return;
		}
		host.getNotifications().publish(label + " in progress…", feedback.NotificationKind.Information, "source-control");
		var operationId = nextOperationId();
		source.apply(repository.id, operationId, snapshot.revision, operation, function(result) {
			if (result.error != null) {
				host.getNotifications().publish("Branch operation failed: " + result.error.message,
					feedback.NotificationKind.Error, "source-control");
				reportError(result.error.message);
			} else {
				host.getNotifications().publish(label, feedback.NotificationKind.Information, "source-control");
				source.refreshNow(repository.id);
			}
			requestFrame();
		});
	}

}
