# Third-Party Licenses and Attribution

This repository is licensed under MIT No Attribution (MIT-0). See
[LICENSE](LICENSE).

**Nothing third-party is bundled or redistributed here.** This repository
contains only first-party source, infrastructure-as-code and documentation. Every
item below is either resolved from a package registry at build time, pulled from
a container registry at image-build time, or fetched from its own upstream
repository at deploy time. No third-party source code, no container image layers,
and no machine-learning model weights are stored in or distributed by this
repository.

Licenses are recorded below as published by each project. Exact dependency
versions are pinned or ranged in the package manifests
(`package.json`, `package-lock.json`, `pyproject.toml`); verify the license of
the specific version you resolve, since a project may relicense across versions.

## Deployed workload — fetched at deploy time, not vendored

| Project | Publisher | License | How it is used |
|---|---|---|---|
| [one-observability-demo](https://github.com/aws-samples/one-observability-demo) (PetAdoptions) | AWS Samples | MIT-0 | The entire demo workload. Cloned inside AWS CodeBuild at a git ref pinned in `config/accounts.json` and deployed **unforked and unmodified**. The frontend petsite is built from unmodified upstream source. This repository adds an overlay (alarms, roles, PrivateLink, FIS templates) alongside it and never edits upstream files. |

## Agent frameworks and protocols

| Project | Publisher | License |
|---|---|---|
| [Strands Agents SDK](https://github.com/strands-agents/sdk-python) (`strands-agents`) | AWS | Apache-2.0 |
| [Strands Agents Tools](https://github.com/strands-agents/tools) (`strands-agents-tools`) | AWS | Apache-2.0 |
| [Model Context Protocol Python SDK](https://github.com/modelcontextprotocol/python-sdk) (`mcp`) | Anthropic / MCP project | MIT |
| [A2A Python SDK](https://github.com/a2aproject/a2a-python) (`a2a-sdk`) | Linux Foundation / A2A project | Apache-2.0 |
| [Agent Skills specification](https://agentskills.io) | Agent Skills project | Specification only — the `SKILL.md` files in `agents/skills/` are first-party content authored to that format |

## AWS SDKs and infrastructure tooling

| Project | Publisher | License |
|---|---|---|
| [AWS CDK library](https://github.com/aws/aws-cdk) (`aws-cdk-lib`, `aws-cdk`) | AWS | Apache-2.0 |
| [constructs](https://github.com/aws/constructs) | AWS | Apache-2.0 |
| [Boto3](https://github.com/boto/boto3) / [botocore](https://github.com/boto/botocore) | AWS | Apache-2.0 |
| [git-remote-s3](https://github.com/awslabs/git-remote-s3) | AWS Labs | Apache-2.0 |

Installed into the CodeBuild environment at build time by
`workload/backend/deploy/cfn-codebuild-stack.yaml`: `aws-cdk`, `typescript`,
`ts-node`, `git-remote-s3`.

## Runtime web/server libraries

| Project | Publisher | License |
|---|---|---|
| [Uvicorn](https://github.com/encode/uvicorn) | Encode | BSD-3-Clause |
| [Starlette](https://github.com/encode/starlette) | Encode | BSD-3-Clause |

## Development and test dependencies

Not present in any deployed artifact.

| Project | License |
|---|---|
| [pytest](https://github.com/pytest-dev/pytest) | MIT |
| [pytest-asyncio](https://github.com/pytest-dev/pytest-asyncio) | Apache-2.0 |
| [pytest-mock](https://github.com/pytest-dev/pytest-mock) | MIT |
| [httpx](https://github.com/encode/httpx) | BSD-3-Clause |
| [moto](https://github.com/getmoto/moto) | Apache-2.0 |
| [Jest](https://github.com/jestjs/jest) | MIT |
| [ts-jest](https://github.com/kulshekhar/ts-jest) | MIT |
| [ts-node](https://github.com/TypeStrong/ts-node) | MIT |
| [TypeScript](https://github.com/microsoft/TypeScript) | Apache-2.0 |
| [DefinitelyTyped](https://github.com/DefinitelyTyped/DefinitelyTyped) (`@types/*`) | MIT |
| [source-map-support](https://github.com/evanw/node-source-map-support) | MIT |
| [hey](https://github.com/rakyll/hey) | Apache-2.0 — optional load-generation tool, referenced by `loadgen/run.sh` and installed by the operator; not bundled |

## Container base images — pulled at image-build time

These images are pulled from public registries when `scripts/deploy-all.sh`
builds container images locally. No image layers are redistributed by this
repository.

| Image | Publisher | Terms |
|---|---|---|
| `python:3.11-slim` | Docker Official Images | Python itself is under the [PSF License](https://docs.python.org/3/license.html). The image also contains Debian base packages under their own licenses (a mix of GPL, LGPL, MIT and BSD). See the [Docker Official Image repository](https://github.com/docker-library/python) for the per-image license inventory. Used by `agents/backend-agent`, `agents/kb-agent` and `mcp-servers/backend-diagnostics`. |
| `mcr.microsoft.com/dotnet/sdk:8.0`<br>`mcr.microsoft.com/dotnet/aspnet:8.0` | Microsoft | The .NET platform is licensed under [MIT](https://github.com/dotnet/runtime/blob/main/LICENSE.TXT). The container images are additionally subject to the [Microsoft container image legal notice](https://github.com/dotnet/dotnet-docker/blob/main/README.md#license) and may include components under Microsoft's own terms. Used by `workload/frontend/docker/Dockerfile`, which builds the petsite application from unmodified upstream PetAdoptions source. |

## AWS services

The AWS services this sample uses — including AWS DevOps Agent, Amazon Bedrock,
Amazon Bedrock AgentCore Runtime, Amazon Bedrock Knowledge Bases, Amazon ECS,
Amazon Aurora, Amazon DynamoDB, Amazon SQS, AWS Lambda, Amazon CloudWatch
(including Synthetics), AWS Fault Injection Service, AWS PrivateLink, AWS Systems
Manager Parameter Store, Amazon S3 and Amazon SNS — are governed by the
[AWS Customer Agreement](https://aws.amazon.com/agreement/) and the
[AWS Service Terms](https://aws.amazon.com/service-terms/), not by this
repository's license.

Foundation models are invoked through Amazon Bedrock and are subject to their
provider's terms and to the
[AWS Responsible AI Policy](https://aws.amazon.com/machine-learning/responsible-ai/policy/).
Model access must be requested by the deploying account owner; see
`docs/deployment.md`. No model weights are downloaded, bundled or redistributed
by this repository.
