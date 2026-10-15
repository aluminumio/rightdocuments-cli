# rightdocuments

CLI for the [RightDocuments](https://app.rightdocuments.com) API. Crystal binary, distributed via Homebrew and GitHub Releases.

## Install

    brew install aluminumio/tap/rightdocuments

Or download a binary from [Releases](https://github.com/aluminumio/rightdocuments-cli/releases).

## Use

    rightdocuments login                                  # OAuth device-flow login
    rightdocuments whoami [-j]
    rightdocuments profiles [-j]                          # stored logins and their organizations
    rightdocuments entities [-j]
    rightdocuments entities:create --name NAME --type llc --state DE [-j]
    rightdocuments documents ENTITY_ID [-j]
    rightdocuments documents --matter 0004-001 [-j]       # or --client 4; id, name, status
    rightdocuments import path/to/file.pdf --entity ENTITY_ID [-j]
    rightdocuments import path/to/file.pdf --matter 0004-001 [--name NAME] [-j]
    rightdocuments documents:info DOCUMENT_ID [-j]        # status and stored files with sizes
    rightdocuments documents:download DOCUMENT_ID [filed|executed|unsigned|certificate|original|ASSET_KEY] [-o PATH] [--all] [--stdout] [-f]
    rightdocuments documents:void DOCUMENT_ID [-j]        # hide; restore or delete later
    rightdocuments documents:restore DOCUMENT_ID [-j]
    rightdocuments documents:delete DOCUMENT_ID           # admins, voided documents only
    rightdocuments clients [--status engaged] [--type business] [-j]   # client numbers
    rightdocuments clients:info 4 [-j]                    # number, exact name, or ID; lists its documents
    rightdocuments clients:create --name NAME --type business --email EMAIL [--entity COMPANY] [-j]
    rightdocuments clients:update 4 --status engaged --notes NOTES [-j]   # organization admins
    rightdocuments clients:delete 4 --yes                 # organization admins; clients without matters
    rightdocuments matters [--status open|closed] [--client 4] [-j]
    rightdocuments matters:info 0004-001 [-j]             # parties, deadlines, documents
    rightdocuments matters:create --client 4 --name "Malone v. Olde Towne Tavern" [-j]
    rightdocuments matters:update 0004-001 --type pre_litigation --role claimant [-j]
    rightdocuments matters:delete 0004-001 --yes          # organization admins; matters without documents
    rightdocuments parties 0004-001 [-j]
    rightdocuments parties:add 0004-001 --name NAME --role adverse_party [--address "Line 1\nLine 2"] [-j]
    rightdocuments parties:remove 0004-001 PARTY_ID
    rightdocuments deadlines 0004-001 [-j]
    rightdocuments deadlines:add 0004-001 --name "Tavern responds" --due 2026-09-16 [--notes NOTES] [-j]
    rightdocuments deadlines:done 0004-001 DEADLINE_ID     # also deadlines:reopen, deadlines:remove
    rightdocuments cases:open 0004-001 --court "Superior Court of California, County of San Francisco" \
      --court-code ca_sf_superior --type unlimited [--jury] [--efsp "One Legal"] [-j]
    rightdocuments cases:info 0004-001 [-j]               # or the case ID or case number; facts with source documents
    rightdocuments filings:add 0004-001 --document DOC_ID --kind complaint [--fees 435.00] [--efsp-ref REF] \
      [--endorsed ./stamped.pdf --case-number CGC-26-612345 --filed 2026-10-10] [-j]
    rightdocuments filings:list 0004-001 [-j]             # filings:* are kept; new work uses submissions:*
    rightdocuments submissions DOCUMENT_ID [-j]           # where the document was sent, and what came back
    rightdocuments submissions:add DOCUMENT_ID --to court|sos|irs|agency|party [--case CASE] [--kind complaint] \
      --channel efsp --provider "One Legal" --submitted 2026-10-10T22:40 [--reference ENV-1] [--fees 435.00] [-j]
    rightdocuments submissions:accept SUBMISSION_ID --copy ./stamped.pdf [--returned acceptance|filed_copy|certified_copy] \
      [--received 2026-10-10T23:00] [--filed 2026-10-12] [--case-number CGC-26-612345 | --file-number 7654321 | --ein 12-3456789] [--dry-run] [-j]
    rightdocuments submissions:receipt SUBMISSION_ID [--file ./receipt.pdf] [--reference ENV-1] [-j]
    rightdocuments submissions:reject SUBMISSION_ID --reason "Missing cover sheet" [--file ./notice.pdf] [-j]
    rightdocuments submissions:correct SUBMISSION_ID --reason "Misread the time" [--received 2026-10-13T09:00] [--withdraw] [-j]
    rightdocuments submissions:info SUBMISSION_ID [-j]    # history and the facts it proved
    rightdocuments deliveries DOCUMENT_ID [-j]
    rightdocuments deliveries:add DOCUMENT_ID --channel mail --sent 2026-09-02 --party PARTY_ID [-j]
    rightdocuments deliveries:update DOCUMENT_ID DELIVERY_ID --status delivered --delivered 2026-09-08 [-j]
    rightdocuments deliveries:sync DOCUMENT_ID DELIVERY_ID [-j]         # refresh a mailed letter's tracking
    rightdocuments documents:mail DOCUMENT_ID --party PARTY_ID [--service certified] --yes   # real letter; postage is charged
    rightdocuments skills                                 # print agent/LLM usage guide
    rightdocuments logout

Pass `-j`/`--json` on any data command for machine-readable output. Run `rightdocuments skills` for an end-to-end walkthrough an LLM/agent can consume directly.


## Profiles

Each login is bound to one organization. To use more than one organization at the same time, give each login a name with `--profile` (like the AWS CLI):

    rightdocuments login --profile siegel-bebeni          # select the organization in the browser
    rightdocuments clients --profile siegel-bebeni
    export RIGHTDOCUMENTS_PROFILE=siegel-bebeni           # or set it once for the shell
    rightdocuments profiles                               # * marks the profile in use

Without `--profile` or `$RIGHTDOCUMENTS_PROFILE`, the CLI uses the `default` profile. Tokens are kept in `~/.netrc` (`machine NAME@app.rightdocuments.com`; the default profile uses the plain host).
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
