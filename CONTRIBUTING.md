# Contributing

## Check a change

Run these from `rust-web` before you open a pull request. CI runs the same commands.

```sh
cargo fmt --all -- --check
cargo clippy --locked --all-targets -- -D warnings
cargo test --locked
python3 -B scripts/test_dev.py
```

The default tests need no credentials. `AGENTS.md` has the rules for user-facing copy.

## How a change arrives

The canonical source is maintained in a private repository. This repository receives snapshots of it, so its history is a series of exports.

A pull request is not merged here. The maintainer applies it to the canonical source and the change arrives with the next snapshot. A direct edit in this repository is lost at the next snapshot.

Real credentials are not part of this repository.
