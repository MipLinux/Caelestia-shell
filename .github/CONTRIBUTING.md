# Contributing

There are only a few rules:

- Follow the commit convention as follows:
    - The name of the commit should be `module: change`
    - Try to be consistent with the module names; you can look at existing commits for the module names I use
    - If there is more than one change, the change in the commit name should be the most impactful change
    - Put other changes in the description
- Format your code
    - I use the vscode qml extension with default arguments to format the code, however you do not have to use it
    - Just try to follow the code style of the rest of the code and ensure that there is:
        - no trailing whitespace on any lines
        - a single space between operators
- No AI slop allowed
    - AI readme/docs slop = instant block
- PLEASE TEST YOUR PRS
    - I can't believe I have to put this here, but please test your PRs before submitting them
    - Your PR must not break anything currently existing, or specify in the description if it does
- PR descriptions should be descriptive
    - Please explain what the PR does and how to use it in your PR description
    - Also include any breaking changes and/or side effects of the PR

## Workflow

- Work is tracked as GitHub issues with the `task` label; the assignee is the owner.
  The issue body must name the files you will touch, and acceptance must be a command
  plus its expected result. See [docs/work/README.md](../docs/work/README.md).
- Draft a task issue with [docs/work/TEMPLATE.md](../docs/work/TEMPLATE.md), then run
  `./scripts/workflow/check-work-issue.sh` before publishing it.
- Fill in [the PR template](pull_request_template.md), including `Closes #N`.
  A PR that closes an issue will get an acceptance reconciliation comment.
- Maintainers can request the strict review with `/mipl-review` (or `/caelestia-review`)
  on a PR. The review only describes problems; it is not a merge gate.
- Read [AGENTS.md](../AGENTS.md) before using an AI agent in this repository.
