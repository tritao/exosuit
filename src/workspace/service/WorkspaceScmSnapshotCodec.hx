package workspace.service;

import scm.ScmChangeKind;
import scm.ScmConflictKind;
import scm.ScmGroup;
import scm.ScmGroupId;
import scm.ScmHead;
import scm.ScmHeadOperation;
import scm.ScmResource;
import scm.ScmSnapshot;
import workspace.service.WorkspaceScmProtocol.WorkspaceScmGroup;
import workspace.service.WorkspaceScmProtocol.WorkspaceScmHead;
import workspace.service.WorkspaceScmProtocol.WorkspaceScmResource;
import workspace.service.WorkspaceScmProtocol.WorkspaceScmSnapshot;

/** Converts source-control snapshots at the shared RPC boundary. */
class WorkspaceScmSnapshotCodec {
	public static function encode(value:ScmSnapshot):WorkspaceScmSnapshot {
		return {revision: value.revision, head: encodeHead(value.head),
			groups: [for (group in value.groups) encodeGroup(group)], truncated: value.truncated};
	}

	public static function decode(value:WorkspaceScmSnapshot):ScmSnapshot {
		var groups:Array<ScmGroup> = [];
		for (group in value.groups) {
			var id:Null<ScmGroupId> = switch group.id {
				case "merge": ScmGroupId.Merge;
				case "index": ScmGroupId.Index;
				case "workingTree": ScmGroupId.WorkingTree;
				case "untracked": ScmGroupId.Untracked;
				case _: null;
			};
			if (id != null) groups.push(new ScmGroup(id, [for (resource in group.resources) decodeResource(resource)]));
		}
		return new ScmSnapshot(value.revision, decodeHead(value.head), groups, value.truncated);
	}

	static function encodeHead(value:ScmHead):WorkspaceScmHead
		return {branch: value.branch, detachedCommit: value.detachedCommit, unborn: value.unborn,
			upstream: value.upstream, ahead: value.ahead, behind: value.behind, upstreamGone: value.upstreamGone,
			operation: value.operation};

	static function encodeGroup(value:ScmGroup):WorkspaceScmGroup
		return {id: value.id, resources: [for (resource in value.resources) encodeResource(resource)]};

	static function encodeResource(value:ScmResource):WorkspaceScmResource
		return {path: value.path, originalPath: value.originalPath, pathBytes: value.pathBytes,
			originalPathBytes: value.originalPathBytes, changeKind: value.changeKind, conflictKind: value.conflictKind,
			submoduleStatus: value.submoduleStatus, renameScore: value.renameScore};

	static function decodeHead(value:WorkspaceScmHead):ScmHead
		return new ScmHead(value.branch, value.detachedCommit, value.unborn, value.upstream, value.ahead, value.behind,
			value.upstreamGone, cast decodeHeadOperation(value.operation));

	static function decodeHeadOperation(value:String):ScmHeadOperation
		return switch value {
			case "merge": ScmHeadOperation.Merge;
			case "rebase": ScmHeadOperation.Rebase;
			case "cherry-pick": ScmHeadOperation.CherryPick;
			case "revert": ScmHeadOperation.Revert;
			case "bisect": ScmHeadOperation.Bisect;
			case _: ScmHeadOperation.None;
		};

	static function decodeResource(value:WorkspaceScmResource):ScmResource {
		var kind:ScmChangeKind = switch value.changeKind {
			case "added": ScmChangeKind.Added;
			case "deleted": ScmChangeKind.Deleted;
			case "renamed": ScmChangeKind.Renamed;
			case "copied": ScmChangeKind.Copied;
			case "type-changed": ScmChangeKind.TypeChanged;
			case "unmerged": ScmChangeKind.Unmerged;
			case "untracked": ScmChangeKind.Untracked;
			case "ignored": ScmChangeKind.Ignored;
			case _: ScmChangeKind.Modified;
		};
		var conflict:Null<ScmConflictKind> = switch value.conflictKind {
			case "both-added": ScmConflictKind.BothAdded;
			case "both-modified": ScmConflictKind.BothModified;
			case "both-deleted": ScmConflictKind.BothDeleted;
			case "added-by-us": ScmConflictKind.AddedByUs;
			case "added-by-them": ScmConflictKind.AddedByThem;
			case "deleted-by-us": ScmConflictKind.DeletedByUs;
			case "deleted-by-them": ScmConflictKind.DeletedByThem;
			case "unknown": ScmConflictKind.Unknown;
			case _: null;
		};
		return new ScmResource(value.pathBytes, kind, value.originalPathBytes, conflict, value.submoduleStatus, value.renameScore);
	}
}
