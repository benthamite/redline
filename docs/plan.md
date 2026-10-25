# Plan: an Emacs package for Roughdraft-style Markdown review

Working name: `critic-review` (not final; avoids implying affiliation with
Roughdraft).

## Goal

Review Markdown files in Emacs the way Roughdraft
(https://github.com/peterhartree/roughdraft) does in its web/desktop app:
comment on passages, reply in threads, suggest insertions/deletions/
replacements, accept or reject suggestions, resolve items, and hand the file to
an AI agent that reads and answers the review. Files written by this package
must be readable by Roughdraft and by agents following Roughdraft's spec, and
vice versa.

## Non-goals (first release)

- No server, browser UI, MCP server or CLI. Pure Elisp.
- No "suggest mode" that turns ordinary typing into suggestions (deferred to a
  second release; hardest piece to get right).
- No GitHub link/push, project file browser, or multi-file workspace features.
- No dependency on the `roughdraft` npm package.

## Format

Target: Roughdraft Flavored Markdown 0.2
(`docs/spec/roughdraft-flavored-markdown.md` in the Roughdraft repo).

Read:
- CriticMarkup markers `{>>…<<}`, `{++…++}`, `{--…--}`, `{~~old~>new~~}`,
  `{==…==}`, ignoring markers inside inline code spans and fenced code blocks.
- Anchored comments: a highlight followed by one or more comments.
- Trailing comments after a suggestion attach to it.
- Compact references `{#id}` plus the final `---` YAML endmatter block
  (`comments:` / `suggestions:` maps with `by`, `at`, `re`, `status`,
  `resolved`, `reaction`, `body`), recognised only under the spec's three
  conditions (not in a fence or frontmatter; parses as a map with `comments` or
  `suggestions`; uses a compact ref or a full comment entry).
- Legacy inline attribute blocks `{id="c1" by="…" at="…"}` with `\"`/`\\`
  escapes, and legacy `{@id:…; by:…; at:…@}`.
- Empty inline comment + endmatter `body` = one comment (multi-paragraph
  bodies). Ignore `re` on an entry whose `body` differs from non-empty inline
  text. A `re` to a missing id becomes top-level; self-parent rejected.

Write:
- Always compact refs + endmatter for new items. Leave existing legacy inline
  attribute blocks as they are unless the item is edited (then migrate that
  item only).
- Ids `c1, c2…` and `s1, s2…`: next free number over both inline and endmatter
  ids.
- `by`: user option, default `"user"` (Roughdraft's label; `"AI"` marks
  agents). `at`: ISO 8601 UTC with milliseconds.
- Refuse comment/reply text containing `<<}` or other close delimiters
  (spec: writers without escaping MUST reject). Multi-paragraph root comment
  text goes to endmatter `body` with an empty inline comment.
- Preserve unknown endmatter keys and unknown attributes, including after an
  edit to the same entry (not just on a no-op round trip).
- Validate every payload before writing: anchor text must not contain `==}`,
  insertion/deletion text not `++}`/`--}`, substitution text not `~>`/`~~}`,
  comment text not `<<}`. Reject selections that cross a paragraph boundary,
  partially overlap an existing review span, or touch a code span or fenced
  block. Validation happens before any buffer change.
- Replying to (or resolving/reacting to) an item that has no id — plain
  CriticMarkup without metadata — first assigns it an id and `by`/`at`
  endmatter in the same change, so the `re` survives save and reopen.

YAML: Emacs has no built-in YAML parser. Use the `yaml` package (zkry/yaml.el,
on MELPA) for parsing the endmatter only. Emit endmatter with a small
purpose-built writer for the known keys (scalars plus `|-` block scalars),
keeping key order: existing entries in their original order, new ones
appended. Values of unknown keys are carried over as their original YAML
source text (captured per entry when reading), not re-serialised, so
sequences and nested maps survive. If an entry cannot be split cleanly into
per-key source text, mutations of that entry are refused with an error. Rewriting the endmatter block normalises its
formatting; the round-trip contract only requires preserving data, but this is
a visible diff on first edit of a hand-formatted block. Accept that.

## Architecture

One package, a few files:

- `critic-review-parse.el`: buffer scanner → list of item structs (kind, id,
  positions of markers/anchor/body/ref, metadata, parent). Code-context
  detection: own scanner for fenced blocks (``` and ~~~, CommonMark rules) and
  backtick code spans; does not rely on `markdown-mode` font-lock state (which
  is lazy and may be stale).
- `critic-review-endmatter.el`: locate, parse and write the endmatter block.
- `critic-review.el`: minor mode `critic-review-mode` for `markdown-mode`/
  `gfm-mode` (works in any text mode), display, commands, keymap.

Parsing is whole-buffer. Display is refreshed on an idle timer after
changes. Every mutating command parses afresh first (cached result reused only
when `buffer-chars-modified-tick` is unchanged), so commands never act on
stale positions. Bulk operations (accept/reject all, remove resolved threads)
apply edits from the end of the buffer backwards and update the endmatter
last. Documents are prose files of at most tens of thousands of words;
measure, and only add incremental parsing if needed.

## Display

- Overlays, rebuilt after each parse (not font-lock), so display does not
  fight `markdown-mode` fontification.
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
- Threads: a side window (`*critic-review: FILE*`) showing the thread at
  point, updated as point moves; plus a list buffer of all items
  (tabulated-list) with jump-to. Margin display rejected: long threads do not
  fit and margins conflict with other margin users.

## Commands (prefix keymap, default `C-c C-r` in the mode; user can rebind)

- comment: on region → anchored comment; without region → standalone comment
  at point.
- reply to item at point (written to endmatter with `re`).
- edit own comment; delete comment (and its replies, after confirmation).
- suggest insertion at point; suggest deletion of region; suggest replacement
  of region (prompt for new text).
- accept / reject suggestion at point; accept/reject all (with confirmation).
  Accept insertion → keep text; deletion → remove text; substitution → new
  text. Reject is the reverse. Endmatter entry removed; attached comments are
  removed too. (Must be checked against Roughdraft's actual accept/reject
  behaviour in its source before implementing; mirror it.)
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

Public package must not hard-depend on agent.el. Provide
`critic-review-send-function` (user option, default nil → copy a prompt to the
kill ring). The prompt tells the agent: the file path, that it uses Roughdraft
Flavored Markdown 0.2 (with a link to the spec), and to read open threads,
reply in endmatter with `by: AI`, and not to apply suggestions unless asked.
Save the buffer first. The mode enables `auto-revert-mode` so the agent's
edits appear; when the buffer has unsaved changes at that point, Emacs's
standard supersession prompt applies (no silent merge). After a revert the
thread window is refreshed. Pablo's dotfiles set the function to send to the live
agent.el session for the project.

## Interop and tests

- ERT tests, written from scratch. Roughdraft's repo has **no license**, so
  its fixtures and spec text must not be copied into this public repo. Tests
  reproduce the spec's cases independently; Roughdraft's fixtures may be read
  locally as reference only.
- Round-trip tests: parse → no-op write leaves the buffer byte-identical;
  each command produces the expected Markdown.
- Behaviour checks pinned to Roughdraft commit
  `3d4b485a5d3deeb4136a23f10c6ef164cfa607fc` (bump deliberately). Format
  compatibility (what the spec allows) and app-behaviour parity (what
  Roughdraft does) are tracked separately.
- Live interop check before release, both directions, with save and reopen
  in each app: comments, multi-paragraph bodies, replies, legacy inline
  metadata (and its migration on edit), accept/reject including removal of
  comments attached to the suggestion, resolve and remove-resolved.
  Roughdraft runs via the untrusted-run wrapper.
- Emacs UI checks in a live session: commands target the right item with
  markup hidden, and one undo restores both inline text and endmatter.
- Edit tests: unknown YAML values (sequences, nested maps) survive an edit to
  the same entry; invalid payloads and overlapping selections are rejected
  with the buffer unchanged.
- Batch byte-compile clean, checkdoc clean, package-lint clean.

## Packaging and publication

- Local repo `~/repos/critic-review`; GitHub `benthamite/critic-review`
  (public), created only once the first release works.
- License GPL-3.0-or-later (Pablo's usual for Emacs packages — to confirm).
- Org manual + generated README, per Pablo's package conventions; add to
  `my-emacs-packages.org`.
- Install in dotfiles via Elpaca recipe in `config.org`; dotfiles configures
  the agent send function.
- Dependencies: Emacs ≥ 29.1, `yaml`. `markdown-mode` optional.

## Open questions

1. Final name.
2. Whether the `yaml` dependency is acceptable or a minimal own YAML reader for
   the restricted endmatter shape is preferable (avoids a dependency; risk of
   misreading hand-edited YAML).
3. Whether to also ship an Org-mode variant later (out of scope here).
