# magit-autorefresh

Refresh Magit status buffers when the repository changes outside Emacs
(terminal, other editors, agents, auto-commit jobs).

## How it works

Every `magit-autorefresh-interval` seconds (default 2), each *visible*
`magit-status-mode` buffer is polled with an async

    git status --porcelain=v2 --branch --show-stash

The output plus the mtimes of the listed paths is hashed; if the hash
differs from the one recorded at the last refresh, the buffer is
refreshed.

- Snapshot comparison means no refresh loops and ignored files never
  trigger a refresh.
- Polls run with `GIT_OPTIONAL_LOCKS=0`, so they never take `index.lock`.
- Refresh is deferred while the region is active, the minibuffer is
  open, a transient menu is up, or a Magit git process is running.
- Hidden buffers are not polled; they catch up when shown again.
- Remote (TRAMP) repositories are skipped.

## Make polling cheap: Git fsmonitor

On macOS/Windows with Git >= 2.37, enable the builtin filesystem
monitor per repository (or `M-x magit-autorefresh-enable-fsmonitor`):

    git config core.fsmonitor true
    git config core.untrackedCache true

## Setup

With Emacs 30+ (`use-package` with built-in `package-vc` support):

```elisp
(use-package magit-autorefresh
  :ensure nil
  :vc (:url "https://github.com/TatuLahtela/magit-autorefresh" :rev :newest)
  :after magit
  :config (magit-autorefresh-mode 1))
```

Or install manually with
`M-x package-vc-install RET https://github.com/TatuLahtela/magit-autorefresh RET`.

## Development

    make compile   # byte-compile, warnings are errors
    make test      # ERT tests against temporary repositories
