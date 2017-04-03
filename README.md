# Cockroach Go

A [Homebrew] tap to install [Cockroach Labs]'s patched version of Go. This
currently includes the following patch:

  * [parallelbuilds-go1.8.patch], which enables parallel compilation of cgo.
    This vastly speeds up a fresh compilation of CockroachDB, which compiles
    RocksDB via cgo.

This repository may ship additional patches in the future, or it may
cease to exist entirely if patches are merged upstream.

[Cockroach Labs]: https://cockroachlabs.com
[Homebrew]: https://brew.sh
[parallelbuilds-go1.8.patch]: https://github.com/cockroachdb/cockroach/blob/c49869212687e3d3c86876f0074690b50e7b7f33/build/parallelbuilds-go1.8.patch


## Installation

With Homebrew installed, run:

```shell
$ brew install cockroachdb/go/cockroach-go
```

If you've already installed Go via Homebrew, you'll be prompted to
unlink it first. You can do so preemptively with `brew unlink go`.

