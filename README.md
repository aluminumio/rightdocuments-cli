# rightdocuments

CLI for the [RightDocuments](https://app.rightdocuments.com) API. Crystal binary, distributed via Homebrew and GitHub Releases.

## Install

    brew install aluminumio/tap/rightdocuments

Or download a binary from [Releases](https://github.com/aluminumio/rightdocuments-cli/releases).

## Use

    rightdocuments login                                  # OAuth device-flow login
    rightdocuments whoami [-j]
    rightdocuments entities [-j]
    rightdocuments entities:create --name NAME --type llc --state DE [-j]
    rightdocuments documents ENTITY_ID [-j]
    rightdocuments import path/to/file.pdf --entity ENTITY_ID [-j]
    rightdocuments logout

Pass `-j`/`--json` on any data command for machine-readable output.

## Claude / agent skill

A Claude Code skill that documents the full workflow (login → create entity → import documents) lives at [`skills/rightdocuments-cli/SKILL.md`](skills/rightdocuments-cli/SKILL.md). Install for your user with:

    mkdir -p ~/.claude/skills/rightdocuments-cli
    cp skills/rightdocuments-cli/SKILL.md ~/.claude/skills/rightdocuments-cli/

## Build from source

    shards install
    shards build --release
    ./bin/rightdocuments --help

## Configuration

Environment variables:

| Variable | Default | Purpose |
|---|---|---|
| `RIGHTDOCUMENTS_URL` | `https://app.rightdocuments.com` | API host (override for self-hosted or dev) |
| `RIGHTDOCUMENTS_CLIENT_ID` | (production app id) | OAuth client id |

Tokens are persisted in `~/.netrc`.
