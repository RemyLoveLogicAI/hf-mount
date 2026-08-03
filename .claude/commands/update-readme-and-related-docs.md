---
name: update-readme-and-related-docs
description: Workflow command scaffold for update-readme-and-related-docs in hf-mount.
allowed_tools: ["Bash", "Read", "Write", "Grep", "Glob"]
---

# /update-readme-and-related-docs

Use this workflow when working on **update-readme-and-related-docs** in `hf-mount`.

## Goal

Keeps the README and documentation files in sync with code changes, bug fixes, or new features.

## Common Files

- `README.md`
- `_docs/README.md`
- `_docs/DEPENDENCIES.md`
- `_docs/src/README.md`
- `_docs/src/setup.rs.md`

## Suggested Sequence

1. Understand the current state and failure mode before editing.
2. Make the smallest coherent change that satisfies the workflow goal.
3. Run the most relevant verification for touched files.
4. Summarize what changed and what still needs review.

## Typical Commit Signals

- Edit implementation or test files as needed
- Update README.md to reflect the latest changes
- Update related documentation files in _docs/ (e.g., _docs/README.md, _docs/DEPENDENCIES.md, _docs/src/README.md, _docs/src/setup.rs.md)
- Fix references and ensure documentation is consistent

## Notes

- Treat this as a scaffold, not a hard-coded script.
- Update the command if the workflow evolves materially.