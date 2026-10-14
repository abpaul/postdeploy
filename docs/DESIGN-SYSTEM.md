# PostDeploy Design System

Moved. The design system is one file: **`DESIGN.md` at the root of this Elixir
application** (`elixir/DESIGN.md`, the git repository root). The path
`AL+/DESIGN.md` one level up is a symlink to the same file, so either path
reads the same content.

It carries the design direction, the public and dashboard recipes, the voice
and punctuation rules, and an implementation appendix with the token and class
vocabulary, the primitives, the table recipe, and the component rules that used
to live here.

The visual authority remains `designSystem/PostDeploy v3.dc.html`. Token values
remain in `assets/css/alp/tokens.css`, mapped to classes in `theme.css`. Read
values there, never copy them into a template.

This stub exists because code comments and docs across the repository still
cite `docs/DESIGN-SYSTEM.md` by path and section number.
