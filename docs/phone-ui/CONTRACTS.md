# Phone UI: contracts between the tracks

ADR: [0007](../architecture/0007-phone-shell-and-session-index.md). Visual spec: the mockups in
[mockups/](mockups/) (`.dc.html`, plain HTML with inline styles: read the numbers from them). Boards:
`Main` (Sessions, workspace scope), `Terminal`, `Machines`, `Unfolded` (desktop shell when wide), `AllSessions`
(machine scope, sections by state), `NestedGroups` (nested group headers). Sizes in the mockups are CSS px at a
390 px wide phone; treat them as dp.

Every track codes against THESE names and signatures. If one turns out wrong, change it in this file in the same
commit and say so in the report. Nothing here may break the desktop: until PhoneShell is selected, behaviour is
unchanged.

## Design tokens (all tracks)

| Token | Value |
| --- | --- |
| Touch target | 44 dp minimum (buttons, rows, chips' hit area) |
| Session row | 64 dp min height (Main: 72), padding 10-14 / 16 |
| Section header | 12 dp, weight 600, letter-spacing 0.05em, uppercase for state sections, padding 14 16 6 |
| Chip | 13-14 dp text, padding 7-8 / 12-14, radius 16-18, fill #eceef2; active #16181d on white; "Sections: x" chip #e8edfb on #1f3f9e |
| Title switcher | 22 dp weight 600 + chevron-down; subtitle 13 dp #555b66 |
| Bottom bar | 4 equal items, icon 22 + label 12, active #2f55c7 weight 600, top border #e2e4e9, bottom padding = safe area |
| Colors | ground #f4f5f7, surface #ffffff, text #16181d, secondary #555b66, accent #2f55c7, attention #d97706 / #8a4b00, working #2f55c7, idle #9aa0aa |
| Fonts | the app's UI font (IBM Plex Sans in mockups) and its terminal font |

## A. UI kit: scrolling, density, recognizers (haxeon/packages/ui)

- `haxeon.ui.gestures.DragRecognizer`: track velocity (px/s, last 100 ms of samples); `GestureEvent` for drag end
  carries `velocityX`, `velocityY`.
- `haxeon.ui.widgets.scroll.ScrollController`: `fling(velocityX:Float, velocityY:Float):Void` starts momentum
  (exponential decay, friction 0.135 per frame-normalized ~ 2 s to rest from 4000 px/s), stops at the edges with a
  short overscroll glow or clamp; `isFlinging:Bool`. A touch drag on a `ScrollView` scrolls 1:1 and flings on
  release. Mouse wheel unchanged.
- `haxeon.ui.style.Density`: `enum abstract Density(Int) { var Pointer; var Touch; }` and
  `class DensityTokens { public static function of(d:Density):DensityTokens; final rowHeight; final touchTarget;
  final indent; final fontScale; }` (Pointer: today's values; Touch: rowHeight 56, touchTarget 44, indent 16,
  fontScale 1.0). `UiContext.density:Density`, set by the host (`touchPrimary` gives Touch).
- `haxeon.ui.gestures.PinchRecognizer` (two pointers; `scale`, `focusX`, `focusY`; begin/update/end) and
  `haxeon.ui.gestures.SwipeRecognizer` (horizontal flick > 600 px/s and > 48 px; `direction`). Registered through
  the existing `GestureArena`.

## B. UI kit: navigation controls (haxeon/packages/ui/haxe/haxeon/ui/widgets/navigation/)

All are `ScopeView`s like `IconButton` (stable `key`, `inputsEqual`).

```haxe
// A stack of screens; the top one is shown full size. Back (UiContext.handleBack) pops when depth > 1.
class NavigationStack implements ScopeView {
	public function new(key:String, controller:NavigationController, ?style:LayoutStyle);
}
class NavigationController {
	public function new(root:NavigationEntry);
	public var entries(default, null):Array<NavigationEntry>;
	public function push(entry:NavigationEntry):Void;   // slide in from the right, 220 ms
	public function pop():Bool;                           // false at the root
	public function replaceRoot(entry:NavigationEntry):Void;
	public var revision(default, null):Int;
}
typedef NavigationEntry = { id:String, build:Void->View };

class BottomBar implements ScopeView {
	public function new(key:String, items:Array<BottomBarItem>, selected:String, onSelect:String->Void, ?style:LayoutStyle);
}
typedef BottomBarItem = { id:String, icon:IconName, label:String, ?badge:Int };

// Slides up from the bottom over a scrim; drag down or tap the scrim to dismiss.
class BottomSheet implements ScopeView {
	public function new(key:String, title:String, content:View, onDismiss:Void->Void, ?style:LayoutStyle);
}
// A searchable list of choices for a sheet (single or multi select); items may be indented (depth).
class ChoiceList implements ScopeView {
	public function new(key:String, items:Array<ChoiceItem>, selected:Array<String>, multi:Bool,
		onChange:Array<String>->Void, ?searchPlaceholder:String);
}
typedef ChoiceItem = { id:String, label:String, ?detail:String, ?depth:Int };

class Snackbar implements ScopeView {
	public function new(key:String, text:String, ?actionLabel:String, ?onAction:Void->Void, ?style:LayoutStyle);
}
// Pill chip: label, optional trailing chevron or clear (x); `active` uses the dark fill.
class Chip implements ScopeView {
	public function new(key:String, label:String, onClick:Void->Void, active:Bool = false, trailing:ChipTrailing = None,
		?style:LayoutStyle);
}
enum ChipTrailing { None; Chevron; Clear(onClear:Void->Void); }
```

## C. Shell split (graphical/src/ui/shell/)

`graphical/src/ui/shell/Shell.hx` (in this commit) is the interface. `ExosuitApp` keeps the core (sessions,
workspaces, machine client, views, commands) and holds one `shell:Shell`.

- `DesktopShell`: today's dock, rail, tabs, status bar and `ResponsiveLayout`, moved without behaviour change.
- `ShellSelector.choose(width:Float, touchPrimary:Bool, override:Null<String>):ShellKind`: `Phone` when
  `override == "phone"`, or `touchPrimary && width < 600`; `Desktop` when `override == "desktop"` or otherwise.
  Re-evaluated on every resize; a change swaps the shell, re-opening `focusedView()` in the new one.
- Desktop override: `EXOSUIT_FORM_FACTOR=phone` makes the desktop app open a 412x915 window, set `touchPrimary`
  and `Density.Touch`, and choose `PhoneShell`. Mouse input is then delivered as touch (pointer id 0) so the
  phone gestures work with a mouse.
- Scripted input (`haxeon/packages/ui/haxe/haxeon/ui/host/ScriptedInput.hx`, version 1) gains:
  `{"at":s,"type":"touch","action":"begin"|"move"|"end"|"cancel","x":..,"y":..,"id":0}` (maps to
  `PlatformEvent.Touch`), `{"type":"tap","x","y"}` (begin+end 60 ms apart), `{"type":"drag","x","y","dx","dy",
  "ms":200}` (begin, moves every 16 ms, end; a short `ms` makes a fling), `{"type":"back"}` (calls
  `UiContext.handleBack`), `{"type":"resize","width","height"}` (logical size, for fold/unfold). Track C owns this.

## D. Session index

- `src/workspace/sessions/SessionIndex.hx` (types in this commit): entries, query, sections.
- exohost control op `sessions`: request `{"op":"sessions"}`; reply
  `{"ok":true,"machine":{"id","name"},"sessions":[SessionEntry JSON]}` merging every running workspace service's
  sessions and terminals (ask each service as the Workbench does today; a service that does not answer in 2 s is
  listed in `"unavailable":[workspaceId]`). Over the relay a paired device asks the same with `SESSIONS` (184) on
  the machine directory channel, answered only for the workspaces it may read (`workspace.read`); the phone adds
  those sessions to its index for workspaces whose catalog it has not read yet.
- `SessionIndex.query(q:SessionQuery):Array<SessionSection>`: filter by workspace ids, group ids (a group selects
  its descendants), kinds, states, text (name contains, case-insensitive); sort: attention, working, then
  `lastActive` descending; section by `None | Workspace | Group | State | Day`. Group sections are flat, titled with
  the full path (`["11-17-26","phone app"]`), parent before child, a group's direct sessions first.
- The Workbench tree keeps its model in this change; the index feeds PhoneShell (and an All sessions view later).

## E. PhoneShell (graphical/src/ui/shell/phone/)

`PhoneShell implements Shell`, built from B's controls and D's index. Screens, matching the mockups:

1. **Sessions** (`Main`): title switcher `<workspace> ▾` (subtitle `on <machine> · online · N sessions`),
   new-session round button; chips `Group ▾`, `Kind ▾`, `Sections: group`; sessions under group sections
   (`NestedGroups` for depth: `11-17-26 / PHONE APP`, parent part greyed, collapsible chevron, count); row: icon tile,
   name, last line, state badge.
2. **All sessions** (`AllSessions`): title `<machine> ▾` (subtitle `all workspaces · N sessions`), search field,
   chips `Workspace ▾`, `Group ▾`, `Kind ▾`, `Sections: state`; sections NEEDS YOU / WORKING / RECENT; row: state dot,
   name, `workspace · group · kind`, age.
3. **Terminal** (`Terminal`): back, name, `workspace · group · you have control`, menu; the existing `TerminalPane`
   full width; key row Esc, Tab, Ctrl, arrows, Paste, Send (44 dp); system keyboard inset respected.
4. **Machines** (`Machines`): a card per machine with its workspaces (tap: Sessions scoped to it); dead pairings as
   one line with Forget; `Pair a machine`.
5. **Sheets**: the title switcher (machines and their workspaces, plus "All workspaces"), each chip (a `ChoiceList`;
   Group is indented by depth, multi-select, a parent selects its children), session long-press (Rename, Restart,
   Stop, Move to group).
6. **Bottom bar**: Sessions, Files, Search, Machines. Sessions opens All sessions when the scope is the machine, the
   workspace Sessions screen when scoped to one. Files and Search open the existing panels full screen.

Back pops screens only; filters never add a Back step. Unfold (shell swap) keeps the focused session focused.
