# TODO

- [ ] Introduce shared canonical file identity handling for symlink aliases.
  Ctrl-P currently deduplicates normalized paths across overlapping project
  indexes, but aliases through symlinked directories or files can still appear
  as separate candidates. Resolve and cache identities during workspace indexing
  and reuse them for candidate merging and document lookup, without filesystem
  lookups on every picker open or keystroke. Preserve distinct files in separate
  checkouts and scope remote identities by workspace. Cover symlinked roots,
  directories, and files, including retargeted or broken links.
