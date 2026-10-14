# 8. The SDKs live in this repository

Status: Accepted (2026-09-21)

## Context

The three first-party SDKs were extracted into `Alplus-Tech/sdk-js`,
`sdk-elixir` and `sdk-ruby` on 2026-08-20
(`docs/runbooks/transfer-and-sdk-split.md`). A month of working that way
produced a measurable tax and no measurable benefit.

The tax was cross-repository choreography. The contract fixtures the SDKs test
against are owned by the product, so every SDK job checked out this repository
at a pinned commit through a fine-grained token, driven by a repository
variable holding a 40-hex SHA. The compatibility gate ran the other way — a
product workflow checking out three SDKs through a second token — and needed
three commit SHAs typed by hand, which is why its `pull_request` trigger was
still commented out and it never gated a merge. Editing an SDK and the
contract together meant two or three commits in two or three repositories,
with the correctness of the pairing living in a CI variable.

On top of that, an umbrella repository had been created to hold the product
and the SDKs together. It recorded them as bare gitlinks with no
`.gitmodules`, so a clone of it produced four empty directories, and the
commits it pinned had never been pushed.

The benefit that was supposed to justify this was a public SDK source, which
npm provenance also depends on. At the time of this decision the three public
repositories had 0 stars, 0 forks and 0 issues between them, and the npm
package saw about 100 downloads a month — mostly our own CI. The published
packages carried no provenance attestation anyway, because the releases had
been made by hand rather than through the release workflows.

## Decision

All three SDKs live in this repository under `sdks/`, merged with their full
history, beside the `sdks/contract` fixtures they verify against.

- Each SDK keeps its own manifest, version, tests and registry.
- Each publishes from its own directory when its namespaced tag is pushed:
  `elixir-v*`, `js-v*`, `ruby-v*`. The release job refuses to publish when the
  tag and the manifest disagree. No registry requires a dedicated repository:
  Hex authenticates with an API key and binds to no repository at all, and the
  npm and RubyGems trusted publishers bind to a repository *and workflow
  filename*, with no path constraint.
- CI is path-filtered. A change under one SDK runs that SDK alone. A change
  under `sdks/contract` runs the product suite, which contains the server
  parser anchor, and all three SDK suites. That is the compatibility gate;
  `sdk-compat.yml` is deleted.
- The contract tests default to `sdks/contract` in the same checkout, with
  `POSTDEPLOY_CONTRACT_DIR` as an override. Each SDK still pins the contract
  version and every digest in its own code, so one directory edit cannot make
  three SDKs accept drift.

## Consequences

A developer or a coding agent clones once and edits the application, the MCP
server, the contract and every SDK in one worktree; one commit can change a
fixture and all three SDKs, and one CI run proves the three languages and the
server parser still agree.

This repository is private, so the SDK sources are no longer public. npm
provenance is therefore unavailable — it requires a public source repository
and fails with 422 otherwise — so `npm publish` runs without `--provenance`.
Published package metadata points at `postdeploy.dev` rather than a repository
URL, and the archived SDK repositories keep the old links and history alive.

This is reversible. If external adoption ever makes a public SDK source worth
the tax, `git subtree split --prefix=sdks/<name>` reproduces a standalone
repository with history — the same command that created the repositories this
decision retires.
