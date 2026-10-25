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
- Preserve unknown endmatter keys and unknown attributes.

YAML: Emacs has no built-in YAML parser. Use the `yaml` package (zkry/yaml.el,
on MELPA) for parsing the endmatter only. Emit endmatter with a small
purpose-built writer for the restricted shape (two-level maps of scalars plus
`|-` block scalars), keeping key order: existing entries in their original
order, new ones appended. Rewriting the endmatter block normalises its
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

Parsing is whole-buffer, re-run on an idle timer after changes (documents are
prose files of at most tens of thousands of words; measure, and only add
incremental parsing if needed).

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
  summary).
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
Save the buffer first. Pablo's dotfiles set the function to send to the live
agent.el session for the project.

## Interop and tests

- ERT tests, written from scratch. Roughdraft's repo has **no license**, so
  its fixtures and spec text must not be copied into this public repo. Tests
  reproduce the spec's cases independently; Roughdraft's fixtures may be read
  locally as reference only.
- Round-trip tests: parse → no-op write leaves the buffer byte-identical;
  each command produces the expected Markdown.
- Live interop check before release: open a file written by this package in
  Roughdraft (installed via the untrusted-run wrapper) and confirm comments,
  replies and suggestions appear; and the reverse.
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
