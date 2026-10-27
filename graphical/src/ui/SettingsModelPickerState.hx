package ui;

/** Live model paging and retry actions supplied by the settings host. */
class SettingsModelPickerState {
	public final loading:Bool;
	public final error:Null<String>;
	public final hasMore:Bool;
	public final refresh:Void->Void;
	public final more:Void->Void;
	public final retry:Void->Void;
	public function new(loading:Bool, error:Null<String>, hasMore:Bool,
		refresh:Void->Void, more:Void->Void, retry:Void->Void) {
		this.loading = loading; this.error = error; this.hasMore = hasMore;
		this.refresh = refresh; this.more = more; this.retry = retry;
	}
}
