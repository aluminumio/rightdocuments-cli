# rightdocuments

CLI for the [RightDocuments](https://app.rightdocuments.com) API. Crystal binary, distributed via Homebrew and GitHub Releases.

## Install

    brew install aluminumio/tap/rightdocuments

Or download a binary from [Releases](https://github.com/aluminumio/rightdocuments-cli/releases).

## Use

    rightdocuments login                                  # OAuth device-flow login
    rightdocuments whoami
    rightdocuments entities
    rightdocuments documents ENTITY_ID
    rightdocuments import path/to/file.pdf --entity ENTITY_ID
    rightdocuments logout

## Build from source

    shards install
    shards build --release
    ./bin/rightdocuments --help

## Configuration

Environment variables:

| Variable | Default | Purpose |
|---|---|---|
| `RIGHTDOCUMENTS_URL` | `https://app.rightdocuments.com` | API host (override for self-hosted or dev) |
| `RIGHTDOCUMENTS_CLIENT_ID` | `right-cli` | OAuth client id |

Tokens are persisted in `~/.netrc`.
