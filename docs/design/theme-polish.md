# Workbench theme polish

The workbench uses a quiet neutral foundation, with blue reserved for actions, focus and selection. Dark mode steps from a recessed near-black canvas through chrome to raised controls; light mode uses the same hierarchy in soft grays and white. Borders separate controls without turning every region into a box. Primary and secondary text remain distinct from disabled text, while syntax and diagnostic colors retain their meaning.

The editor and graphical controls share semantic defaults through `WorkbenchColors`. User-configured editor colors continue to override those defaults. Terminal foreground and background follow the workbench palette; ANSI colors remain independent.

Selected tabs connect to the editor canvas and retain the existing accent indicator. Compact tab labels and softly rounded toolbar hover surfaces keep the chrome quiet while preserving established hit targets, sidebar selection rails, and status bar geometry.

The desktop dock sits inside a narrow framed surface with a crisp edge and contact shadow. Navigation actions use quiet surfaces until interaction; selection remains clear through the activity rail and tab indicators. Code and per-file diff cards share a fine one-pixel edge in both themes, keeping change tints distinct and preserving native text selection and scroll clipping. The composer uses a plain outlined box, while selection surfaces use a subtle rim and soft shadows.

Acceptance criteria:

- Dark and light workbenches have legible primary and secondary text and distinguish normal, hover, pressed, selected and focused controls.
- Editor, terminal and chrome feel related while selection, search, diagnostics and syntax remain identifiable.
- Switching themes updates shared control styles and the light editor colors, including disabled text and dividers.
- Explicit appearance preferences remain effective; theme defaults do not change syntax classification or editing behavior.

Verification: the native `tests/session-chat-ui` fixture runs the button-theme, sidebar, status, Markdown and session-projection suites alongside session layouts in both themes at 320, 420 and 1000 logical pixels. It checks text contrast, theme switching, control states, layout bounds and interaction routing. Full IDE screenshots in both themes were also reviewed; the fixture itself is a layout and event test rather than a pixel comparison.
