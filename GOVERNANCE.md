# Governance

## Project Leadership

RepoLens is created and maintained by [Cedric Moessner](https://github.com/TheMorpheus407) ([@TheMorpheus407](https://github.com/TheMorpheus407)) under [Bootstrap Academy](https://bootstrap.academy).

Bootstrap Academy is the organizational sponsor and copyright holder (see [NOTICE](NOTICE)). Day-to-day project decisions are made by the maintainer, not by a committee or board.

## Decision-Making

RepoLens follows a **BDFL (Benevolent Dictator for Life)** model. The project maintainer has final authority over all project decisions, including:

- **Feature direction and roadmap** — what capabilities RepoLens gains or drops
- **Lens domain additions and removals** — which expert lenses are included
- **Architecture and design** — how the codebase is structured
- **Releases** — when versions are cut and what they contain
- **Breaking changes** — when and how backward compatibility is broken

Decisions are made transparently. Significant changes are discussed in [GitHub Issues](https://github.com/TheMorpheus407/RepoLens/issues) before implementation.

## Release Cadence

RepoLens releases happen when the `[Unreleased]` section of CHANGELOG.md grows non-trivial — loosely: a screen of bullets, or a user-facing feature lands, or a month has passed with active commits, whichever comes first.

Releases are cut from master by the maintainer:

1. Rename `[Unreleased]` to `[X.Y.Z] — YYYY-MM-DD` in CHANGELOG.md
2. Bump `VERSION` in `repolens.sh`
3. Update the README shields.io badge
4. Tag the commit (`git tag -a vX.Y.Z`)
5. Push the tag

Releases are intentionally manual to keep the maintainer in the loop. Semver applies: bump **minor** for additive changes, **patch** for bug-only releases, **major** for breaking CLI or config changes. The `0.x` series allows the CLI surface to evolve; expect a `1.0.0` cut once the CLI surface has been stable across one full release cycle.

## Contribution Acceptance

All contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for the full contribution process (fork, branch, PR workflow, commit conventions, DCO sign-off).

Pull requests are reviewed by the maintainer and evaluated on:

- **Quality** — clean code, clear intent, no regressions
- **Relevance** — alignment with the project's goals and scope
- **Test coverage** — new functionality must include meaningful tests
- **Domain fit** — new lenses must target a real, actionable analysis area

The maintainer may request changes, suggest alternative approaches, or decline contributions that do not meet these criteria. Declined contributions will include an explanation.

## Conflict Resolution

Disagreements about technical direction, contribution decisions, or community matters are resolved as follows:

1. **Discussion** — raise the concern in a GitHub Issue or PR comment
2. **Maintainer review** — the maintainer considers all perspectives and makes a final decision
3. **Explanation** — decisions are communicated with reasoning, not just a verdict

The maintainer's decision is final. If the project direction fundamentally diverges from a contributor's vision, the Apache-2.0 license explicitly permits forking — this is the intended escape valve for irreconcilable differences.

For community conduct issues, see [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md). For security vulnerabilities, see [SECURITY.md](SECURITY.md).

## Communication

- **GitHub Issues** — proposals, bug reports, feature requests, and governance discussions
- **Pull Requests** — code contributions and reviews
- **Security advisories** — vulnerability reports (see [SECURITY.md](SECURITY.md))

There are no private mailing lists or decision-making channels. All project decisions happen in public on GitHub.

## Evolution

This governance model reflects the current reality of a single-maintainer project. As the contributor community grows, governance will evolve to match:

- Active contributors may be granted review or triage roles
- Decision-making processes may become more collaborative
- New communication channels may be added as the community warrants them

Changes to this governance document will be proposed and discussed in GitHub Issues before being enacted. The goal is always to keep governance honest — describing how the project actually operates, not how it aspires to operate.
