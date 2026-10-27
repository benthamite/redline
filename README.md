# `redline`: Review threads and suggestions in Markdown and Org

`redline` lets you review prose in Emacs the way you would in a word processor, and then hand the review to an AI agent. You comment on passages, reply in threads, suggest insertions, deletions and replacements, accept or reject them, and mark threads resolved. When you're done, one command sends the file to your agent, which answers the open threads in the same file.

The review lives in the file as [CriticMarkup](https://github.com/CriticMarkup/CriticMarkup-toolkit), plus a YAML block at the end for ids, authors, times, replies and status. The format is [Roughdraft Flavored Markdown 0.2](https://github.com/peterhartree/roughdraft/blob/main/docs/spec/roughdraft-flavored-markdown.md), from [Roughdraft](https://github.com/peterhartree/roughdraft), a local Markdown review app. Markdown files reviewed in Emacs therefore open in Roughdraft and vice versa, and any agent that knows the format can take part.

```markdown
Please revisit {==this sentence==}{>>Needs a source.<<}{#c1}.
Add {++one concrete example++}{#s1}.

---
comments:
  c1:
    by: user
    at: "2026-04-28T12:00:00.000Z"
  c2:
    body: I can add one from the intro.
    by: AI
    at: "2026-04-28T12:05:00.000Z"
    re: c1
suggestions:
  s1:
    by: AI
    at: "2026-04-28T12:05:00.000Z"
```

What you get:

- **Markdown and Org.** In Org files the YAML lives in a `#+begin_comment redline` block so it never shows up in exports, and on export the markup is either dropped (giving the original text), applied (giving the text with every suggestion accepted) or kept as is. Markers inside code are always left alone.
- **A clean reading view.** Delimiters and ids are hidden, insertions and deletions are coloured, comments become small indicators, and the item at point shows its raw markup so you can edit it.
- **Threads.** A side window shows the thread at point and follows you through the file. A list shows every thread, and you can reply, resolve, accept or reject from either.
- **Safe edits.** Every command is one undo step covering both the text and the YAML. Commands refuse changes that would produce ambiguous or overlapping markup, and they keep YAML fields written by other tools.
- **Agent hand-off.** The file is saved, a prompt explaining the format is sent to your agent (or copied to the kill ring), and the agent's replies appear in the buffer as it saves them.

## Installation

`redline` requires Emacs 29.1 or later and the [`yaml`](https://github.com/zkry/yaml.el) package. `markdown-mode` and Org are optional.

With Elpaca:

```emacs-lisp
(use-package redline
  :ensure (:host github :repo "benthamite/redline"))
```

With straight.el:

```emacs-lisp
(use-package redline
  :straight (:host github :repo "benthamite/redline"))
```

With the built-in `:vc` keyword (Emacs 30 or later):

```emacs-lisp
(use-package redline
  :vc (:url "https://github.com/benthamite/redline"))
```

## Quick start

Bind the command map to a prefix in `redline-mode-map`:

```emacs-lisp
(with-eval-after-load 'redline
  (keymap-set redline-mode-map "C-c r" 'redline-command-map))
```

Open a Markdown or Org file and run `M-x redline-mode`. Then select a passage and press `C-c r c` to comment on it, `C-c r s` to suggest replacing it, or `C-c r k` to suggest deleting it. `C-c r t` shows the thread at point, `C-c r l` lists all threads, `C-c r a` and `C-c r x` accept or reject the suggestion at point, and `C-c r S` hands the file to an agent.

To send the review straight to an agent instead of copying the prompt, set `redline-send-function` to a function that takes the file name and a prompt.

## Documentation

The [manual](https://stafforini.com/notes/redline/) covers every command and option, the Org-specific behaviour, compatibility with Roughdraft, and the functions for building on the review data. Once the package is installed it is also available in Info as `(redline)`.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
