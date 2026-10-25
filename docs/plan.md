# Plan: redline, CriticMarkup review threads for Markdown and Org in Emacs

## Goal

Review prose files in Emacs the way Roughdraft
(https://github.com/peterhartree/roughdraft) does in its web/desktop app:
comment on passages, reply in threads, suggest insertions/deletions/
replacements, accept or reject suggestions, resolve items, and hand the file to
an AI agent that reads and answers the review.

Markup-agnostic: one core for CriticMarkup review data, with per-markup
adapters for Markdown and Org (and a plain-text fallback). Markdown files
written by redline must be readable by Roughdraft and by agents following
Roughdraft's spec, and vice versa. Org files use the same review data in an
Org-safe container (below); Roughdraft does not open Org files, so Org
compatibility is with agents and with redline itself.

## Non-goals (first release)

- No server, browser UI, MCP server or CLI. Pure Elisp.
- No "suggest mode" that turns ordinary typing into suggestions (deferred to a
  second release; hardest piece to get right).
- No GitHub link/push, project file browser, or multi-file workspace features.
- No dependency on the `roughdraft` npm package.

## Format

Target: Roughdraft Flavored Markdown 0.2
(`docs/spec/roughdraft-flavored-markdown.md` in the Roughdraft repo), referred
to below as "the spec".

Read:
- CriticMarkup markers `{>>…<<}`, `{++…++}`, `{--…--}`, `{~~old~>new~~}`,
  `{==…==}`, ignoring markers in the adapter's code contexts.
- Anchored comments: a highlight followed by one or more comments.
- Trailing comments after a suggestion attach to it.
- Compact references `{#id}` plus the review endmatter (`comments:` /
  `suggestions:` maps with `by`, `at`, `re`, `status`, `resolved`, `reaction`,
  `body`). In Markdown the endmatter is the final `---` YAML block, recognised
  only under the spec's three conditions (not in a fence or frontmatter;
  parses as a map with `comments` or `suggestions`; uses a compact ref or a
  full comment entry). In Org, see the Org adapter.
- Legacy inline attribute blocks `{id="c1" by="…" at="…"}` with `\"`/`\\`
  escapes, and legacy `{@id:…; by:…; at:…@}`.
- Empty inline comment + endmatter `body` = one comment (multi-paragraph
  bodies). Ignore `re` on an entry whose `body` differs from non-empty inline
  text. A `re` to a missing id becomes top-level; self-parent rejected.
- Document-level comments: endmatter entries with `body`, `by`, `at` and no
  `re` and no inline marker (Roughdraft writes these).

Write:
- Always compact refs + endmatter for new items. Leave existing legacy inline
  attribute blocks as they are unless the item is edited (then migrate that
  item only, as Roughdraft does).
- Ids `c1, c2…` and `s1, s2…`: next free number over both inline and endmatter
  ids.
- `by`: user option, default `"user"` (Roughdraft's label; `"AI"` marks
  agents). `at`: ISO 8601 UTC with milliseconds.
- Refuse comment/reply text containing `<<}` or other close delimiters
  (spec: writers without escaping MUST reject). Multi-paragraph root comment
  text goes to endmatter `body` with an empty inline comment.
- Preserve unknown endmatter keys (top-level and per entry) and unknown
  attributes, including after an edit to the same entry.
- Endmatter retention is by item identity. Commands that delete an item
  (accept/reject, delete comment, remove resolved threads) delete its entry and,
  where stated, its replies. Otherwise an entry is dropped on rewrite only if
  it is a metadata-only entry (no `body`) whose `{#id}` reference no longer
  appears in the text, i.e. the user deleted the marked text by hand; it
  carries no content. Entries with a `body` (replies, document-level comments,
  multi-paragraph root comments) are never dropped implicitly; a root whose
  inline marker is gone reads as a document-level comment, and replies to a
  missing parent read as top-level (orphans).
- Validate every payload before writing: anchor text must not contain `==}`,
  insertion/deletion text not `++}`/`--}`, substitution text not `~>`/`~~}`,
  comment text not `<<}`. Reject selections that cross a paragraph boundary,
  overlap or contain an existing review span (no nesting, including wrapping a
  whole span), or touch a code context, metadata (`{#…}`, attribute blocks)
  or the endmatter. Point commands (suggest insertion, standalone comment)
  are rejected when point is inside a code context, metadata, the endmatter or
  an existing review span. The adapter can add constraints (Org container
  safety). Validation happens before any buffer change; a rejected command
  leaves both text and endmatter unchanged.
- Replying to (or resolving/reacting to) an item that has no id — plain
  CriticMarkup without metadata — first assigns it an id and `by`/`at`
  endmatter in the same change, so the `re` survives save and reopen.

YAML: Emacs has no built-in YAML parser. Use the `yaml` package (zkry/yaml.el,
on MELPA) for parsing. Emit endmatter with a small purpose-built writer for
the known keys (scalars plus `|-` block scalars), keeping key order: existing
entries in their original order, new ones appended. Values of unknown keys
are carried over as their original YAML source text (captured per entry when
reading), not re-serialised, so sequences and nested maps survive. If an
entry cannot be split cleanly into per-key source text, mutations of that
entry are refused with an error. Rewriting the endmatter normalises its
formatting (Roughdraft also rewrites it wholesale); only data is preserved.

## Architecture

- `redline-parse.el`: scanner → list of item structs (kind, id, positions of
  markers/anchor/body/ref, metadata, parent). Markup-independent; asks the
  active adapter which regions are code contexts and where the endmatter is.
- `redline-endmatter.el`: parse and write the review YAML; the adapter
  supplies the container (locate, wrap, unwrap).
- `redline-markdown.el`, `redline-org.el`: adapters (below).
- `redline.el`: minor mode `redline-mode`, display, commands, keymap,
  adapter selection.

An adapter is a struct of functions, chosen by major mode via
`redline-adapter-alist` (`markdown-mode`/`gfm-mode` → Markdown, `org-mode` →
Org, anything else → plain). Adapter functions:
- code-regions: list of (beg . end) where markers are literal text;
- paragraph-bounds: for the cross-paragraph check;
- endmatter-locate / endmatter-wrap: find the review block and its YAML text,
  and produce the block from YAML text;
- export setup (Org only).

Code-context detection uses own scanners, not font-lock state (lazy, may be
stale) and not `org-element` (which misparses CriticMarkup, see Org adapter).

Parsing is whole-buffer. Display is refreshed on an idle timer after
changes. Every mutating command parses afresh first (cached result reused only
when `buffer-chars-modified-tick` is unchanged), so commands never act on
stale positions. Bulk operations (accept/reject all, remove resolved threads)
apply edits from the end of the buffer backwards and update the endmatter
last. Documents are prose files of at most tens of thousands of words;
measure, and only add incremental parsing if needed.

### Markdown adapter

- Code contexts: fenced blocks (``` and ~~~, CommonMark fence rules,
  including longer closing fences and indented fences up to 3 spaces),
  backtick code spans (matching backtick-run lengths), YAML frontmatter.
- Endmatter: final `---` YAML block per the spec.

### Org adapter

- Code contexts: `#+begin_src`/`#+begin_example`/`#+begin_export`/
  `#+begin_comment` blocks (other than redline's own), fixed-width `: ` lines,
  inline `src_…{…}`, and `=verbatim=`/`~code~` objects. Org property drawers
  and keyword lines (`#+…:`) are also excluded.
- Clash with Org emphasis: `{` is an Org emphasis pre-character, so Org reads
  `{==x==}` as verbatim, `{++x++}` as strike-through and `{~~a~>b~~}` as
  code. Precedence is positional, scanning left to right: a review opener
  outside any literal context starts a review span, even though Org would
  read it as emphasis; an already-open literal context (block, fixed-width
  line, inline src, or a `=…=`/`~…~` object that opens before the `{`, as in
  `={++x++}=`) suppresses review recognition until it closes. redline's
  overlays use a higher priority than Org's emphasis faces so the review faces
  win. Tests cover both directions for each clashing marker, verbatim and
  code, with literal text around them.
- Endmatter: the same YAML inside a final block
  `#+begin_comment redline` … `#+end_comment`, which Org omits from export.
  No leading `---`. Only a block with that exact parameter is treated as
  endmatter. Container safety: any YAML line (including block-scalar body
  lines and preserved unknown values) that Org could read as block syntax or a
  headline is comma-escaped on write and unescaped on read, using Org's own
  convention (`org-escape-code-in-string` / `org-unescape-code-in-string`),
  so a body containing `#+end_comment` cannot end the block. Tests: such a
  body survives save/reopen and does not leak into export.
- Export: a function on `org-export-before-processing-functions` (installed
  globally by the package, active only for buffers containing CriticMarkup)
  rewrites the export copy before Org expands includes and macros and runs
  Babel, so discarded branches (comments, rejected suggestion text) are never
  evaluated. A second pass on `org-export-before-parsing-functions` handles
  CriticMarkup introduced by includes or macros; that text has already been
  expanded, which the manual documents. Literal examples in code contexts are
  left untouched in every style. Default
  (`redline-org-export-style` = `original`): keep the original text — reject
  pending insertions, keep deleted and old text, drop comments and
  highlights' delimiters. Alternative `accepted`: as if all suggestions were
  accepted. `markup`: leave raw CriticMarkup. The review comment block is
  already excluded by Org.
- Agent hand-off prompt states the Org variant (container and the fact that
  everything else follows the spec).

### Plain adapter

No code contexts; Markdown-style `---` endmatter. Used for `text-mode` and
other modes.

## Display

- Overlays, rebuilt after each parse (not font-lock), so display does not
  fight major-mode fontification.
- Delimiters, refs and inline attribute blocks hidden via overlay `invisible`;
  revealed for the item at point (like `org-appear`); global toggle to show
  raw markup.
- Faces: anchor highlight; insertion (green/underline), deletion
  (red/strike-through), substitution shows old struck and new inserted.
  Resolved items dimmed.
- Comment bodies in the text are hidden; an indicator (e.g. `[c1·2]`, id and
  reply count) is shown after the anchor.
- Every item, including endmatter-only ones (replies, document-level
  comments), has a stable identity (its id). The thread window and the list
  buffer are command targets: the same commands (reply, edit, delete, react,
  resolve) work on the entry at point there and act on the source buffer.
  Orphan replies (`re` to a missing id) list as top-level; thread traversal
  is cycle-safe.
- Threads: a side window (`*redline: FILE*`) showing the thread at point,
  updated as point moves; plus a list buffer of all items (tabulated-list)
  with jump-to. Margin display rejected: long threads do not fit and margins
  conflict with other margin users.
- The endmatter block itself is folded/hidden by default in `redline-mode`.

## Commands

All commands live in `redline-command-map`, which the package does not bind to
a prefix: markdown-mode and Org use most `C-c C-…` keys, and `C-c LETTER` is
reserved for users. The manual suggests a binding; Pablo's dotfiles binds it.
The thread and list buffers have their own single-key maps.

- comment: on region → anchored comment; without region → standalone comment
  at point; with prefix argument → document-level comment.
- reply to item at point (written to endmatter with `re`).
- edit own comment; delete comment (and its replies, after confirmation).
- suggest insertion at point; suggest deletion of region; suggest replacement
  of region (prompt for new text).
- accept / reject suggestion at point; accept/reject all (with confirmation).
  Mirrors Roughdraft's editor (`acceptCriticChange`/`rejectCriticChange` at
  the pinned commit): accept deletes deleted/old text and unwraps
  inserted/new text; reject deletes inserted/new text and unwraps
  deleted/old text. The suggestion's endmatter entry is dropped. What happens
  to comments attached to the suggestion is established in the interop check
  and mirrored.
- resolve / unresolve item at point (`status: resolved`, optional `resolved`
  summary). This is the format's marking, which Roughdraft's app also shows.
- remove resolved threads: deletes comment threads marked resolved (or the
  thread at point), mirroring Roughdraft's CLI `resolve`, which removes threads
  and never touches suggestions.
- react (up/down/clarify) on a comment.
- next/previous item; next/previous unresolved item.
- list items; toggle raw markup display.
- send to agent (below).

All edits are single undo units (`atomic-change-group`).

## Agent hand-off

The package must not hard-depend on agent.el. Provide `redline-send-function`
(user option, default nil → copy a prompt to the kill ring). The prompt tells
the agent: the file path, that it uses Roughdraft Flavored Markdown 0.2 (with
a link to the spec) or redline's Org variant, and to read open threads, reply
in endmatter with `by: AI`, and not to apply suggestions unless asked. Save
the buffer first. The mode enables `auto-revert-mode` so the agent's edits
appear; when the buffer has unsaved changes at that point, Emacs's standard
supersession prompt applies (no silent merge). After a revert the thread
window is refreshed. Pablo's dotfiles set the function to send to the live
agent.el session for the project.

## Interop and tests

- ERT tests, written from scratch. Roughdraft's repo has **no license**, so
  its fixtures and spec text must not be copied into this public repo. Tests
  reproduce the spec's cases independently; Roughdraft's fixtures may be read
  locally as reference only.
- Round-trip tests per adapter: parse → no-op write leaves the buffer
  byte-identical; each command produces the expected text.
- Org tests: each clashing marker parsed as CriticMarkup, not as Org
  emphasis, and `={++x++}=`-style literals left alone; markers in src/example
  blocks and verbatim ignored. Export to ASCII and HTML, with a separate
  expected output per style: `original` and `accepted` contain no active
  CriticMarkup but keep literal examples in code contexts; `markup` keeps
  active markup verbatim; none contains the review block. A macro with a
  visible side effect inside a pending insertion is not evaluated under
  `original`.
- Behaviour checks pinned to Roughdraft commit
  `9e750dc` (2026-10-25; format unchanged since `3d4b485`) (bump deliberately). Format
  compatibility (what the spec allows) and app-behaviour parity (what
  Roughdraft does) are tracked separately.
- Live interop check (Markdown) before release, both directions, with save
  and reopen in each app: comments, multi-paragraph bodies, replies,
  document-level comments, legacy inline metadata (and its migration on
  edit), accept/reject including comments attached to the suggestion,
  resolve and remove-resolved. Roughdraft runs via the untrusted-run
  wrapper.
- Emacs UI checks in a live session, in a Markdown and an Org buffer:
  commands target the right item with markup hidden, and one undo restores
  both inline text and endmatter.
- Edit tests: unknown YAML values (sequences, nested maps) survive an edit to
  the same entry; invalid payloads and overlapping selections are rejected
  with the buffer unchanged.
- Batch byte-compile clean, checkdoc clean, package-lint clean.

## Packaging and publication

- Local repo `~/repos/redline`; GitHub `benthamite/redline` (public),
  created and pushed once the interop checks pass.
- License GPL-3.0-or-later.
- Org manual + generated README, per Pablo's package conventions; add to
  `my-emacs-packages.org`.
- Install in dotfiles via Elpaca recipe in `config.org`; dotfiles configures
  the agent send function.
- Dependencies: Emacs ≥ 29.1, `yaml`. `markdown-mode` and Org optional at
  load time (adapters loaded lazily).
