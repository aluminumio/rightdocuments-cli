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
    rightdocuments import path/to/file.pdf --matter 0004-001 [--name NAME] [-j]
    rightdocuments documents:void DOCUMENT_ID [-j]        # hide; restore or delete later
    rightdocuments documents:restore DOCUMENT_ID [-j]
    rightdocuments documents:delete DOCUMENT_ID           # admins, voided documents only
    rightdocuments clients [-j]                           # client numbers
    rightdocuments matters [--status open|closed] [--client 4] [-j]
    rightdocuments matters:info 0004-001 [-j]
    rightdocuments matters:create --client 4 --name "Malone v. Olde Towne Tavern" [-j]
    rightdocuments matters:update 0004-001 --type pre_litigation --role claimant [-j]
    rightdocuments parties 0004-001 [-j]
    rightdocuments parties:add 0004-001 --name NAME --role adverse_party [--address "Line 1\nLine 2"] [-j]
    rightdocuments parties:remove 0004-001 PARTY_ID
    rightdocuments deadlines 0004-001 [-j]
    rightdocuments deadlines:add 0004-001 --name "Tavern responds" --due 2026-09-16 [--notes NOTES] [-j]
    rightdocuments deadlines:done 0004-001 DEADLINE_ID     # also deadlines:reopen, deadlines:remove
    rightdocuments deliveries DOCUMENT_ID [-j]
    rightdocuments deliveries:add DOCUMENT_ID --channel mail --provider lob --sent 2026-09-02 --party PARTY_ID [-j]
    rightdocuments deliveries:update DOCUMENT_ID DELIVERY_ID --status delivered --delivered 2026-09-08 [-j]
    rightdocuments skills                                 # print agent/LLM usage guide
    rightdocuments logout

Pass `-j`/`--json` on any data command for machine-readable output. Run `rightdocuments skills` for an end-to-end walkthrough an LLM/agent can consume directly.

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
