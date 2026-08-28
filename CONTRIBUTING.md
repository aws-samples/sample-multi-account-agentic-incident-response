# Contributing Guidelines

Thank you for your interest in contributing to our project. Whether it's a bug
report, new feature, correction, or additional documentation, we greatly value
feedback and contributions from our community.

Please read through this document before submitting any issues or pull requests
to ensure we have all the necessary information to effectively respond to your
bug report or contribution.

## Reporting Bugs/Feature Requests

We welcome you to use the GitHub issue tracker to report bugs or suggest
features.

When filing an issue, please check existing open, or recently closed, issues to
make sure somebody else hasn't already reported the issue. Please try to include
as much information as you can. Details like these are incredibly useful:

- A reproducible test case or series of steps
- The version of our code being used
- Any modifications you've made relevant to the bug
- Anything unusual about your environment or deployment

Because this project deploys across three AWS accounts and depends on an
upstream workload, a bug report is far more actionable if it also states:

- Which of the three accounts (frontend, backend, ops) the problem appeared in
- The step of `scripts/deploy-all.sh` that failed, if applicable
- The exit code and the verdict line from any script that failed
  (for example `preflight: PASS` / `check-parameters: PASS — C1-C6 hold`)
- The upstream git ref in use from `config/accounts.json`

Please do not include AWS account IDs, ARNs containing account IDs, email
addresses, or any credential material in an issue. Redact them before posting.

## Contributing via Pull Requests

Contributions via pull requests are much appreciated. Before sending us a pull
request, please ensure that:

1. You are working against the latest source on the *main* branch.
2. You check existing open, and recently merged, pull requests to make sure
   someone else hasn't addressed the problem already.
3. You open an issue to discuss any significant work — we would hate for your
   time to be wasted.

To send us a pull request, please:

1. Fork the repository.
2. Modify the source; please focus on the specific change you are contributing.
   If you also reformat all the code, it will be hard for us to focus on your
   change.
3. Ensure local tests pass. See "Verification" below.
4. Commit to your fork using clear commit messages.
5. Send us a pull request, answering any default questions in the pull request
   interface.
6. Pay attention to any automated CI failures reported in the pull request, and
   stay involved in the conversation.

GitHub provides additional documentation on
[forking a repository](https://help.github.com/articles/fork-a-repo/) and
[creating a pull request](https://help.github.com/articles/creating-a-pull-request/).

### Verification

Please run the repository's own gates before opening a pull request. They are
read-only and make no AWS calls:

```bash
scripts/preflight.sh --strict     # inputs resolve, parameter contract, repo hygiene
scripts/scan-secrets.sh           # no account identifiers or generated resource names
scripts/check-parameters.sh       # parameter ownership contract C1-C6
python3 -m pytest scripts/tests/  # script test suite
```

For changes inside a CDK app or a Python package, also run that component's own
suite (`npx jest` in the four CDK apps, `python3 -m pytest tests/` in the agent
and MCP server packages).

Two repository conventions are enforced and will fail the gates if broken:

- **No account-specific values in the tracked tree.** Account IDs, regions,
  profile names and email addresses belong only in `config/accounts.json`, which
  is git-ignored. See `docs/parameters.md`.
- **Historical run-logs are records.** The dated run-logs in `docs/deployment.md`
  document what specific measured runs produced. Do not rewrite them to match
  new behaviour; add a new entry instead.

Additional ground rules for working in this repository, including with an AI
coding assistant, are in [AGENTS.md](AGENTS.md).

### A note on fault injection

This repository contains tooling that causes real, customer-visible failures
(AWS FIS experiments, a DynamoDB capacity reduction, an autoscaling ceiling).
Only run it in AWS accounts dedicated to this proof of concept, never against a
shared or production account, and always run the matching restore afterwards.
See [chaos/README.md](chaos/README.md).

## Finding contributions to work on

Looking at the existing issues is a great way to find something to contribute
on. As our projects, by default, use the default GitHub issue labels
(enhancement/bug/duplicate/help wanted/invalid/question/wontfix), looking at any
'help wanted' issues is a great place to start. The project's
[roadmap](docs/roadmap.md) also records planned work.

## Code of Conduct

This project has adopted the
[Amazon Open Source Code of Conduct](https://aws.github.io/code-of-conduct).
For more information see the
[Code of Conduct FAQ](https://aws.github.io/code-of-conduct-faq) or contact
opensource-codeofconduct@amazon.com with any additional questions or comments.

## Security issue notifications

If you discover a potential security issue in this project we ask that you
notify AWS/Amazon Security via our
[vulnerability reporting page](http://aws.amazon.com/security/vulnerability-reporting/).
Please do **not** create a public GitHub issue.

## Licensing

See the [LICENSE](LICENSE) file for our project's licensing. We will ask you to
confirm the licensing of your contribution.
