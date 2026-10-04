# RightDocuments CLI — Skill

Drive the RightDocuments API from the shell. The CLI is `rightdocuments` (installed via `brew install aluminumio/tap/rightdocuments`). All data commands accept `-j`/`--json` for machine-readable output — prefer this when piping or parsing.

## Authentication

```sh
rightdocuments login        # OAuth device flow; opens a code URL the user must visit
rightdocuments whoami -j    # confirms current user + organization
rightdocuments logout       # clears stored token (~/.netrc)
```

The token is persisted in `~/.netrc` under the `app.rightdocuments.com` machine.

## End-to-end workflow: create an entity, populate it with documents

### 1. Confirm auth

```sh
rightdocuments whoami -j
```

If this fails with 401, run `rightdocuments login` first. The user must complete the device-authorization flow in a browser before the CLI proceeds.

### 2. Create the entity

```sh
rightdocuments entities:create \
  --name "Acme Holdings, LLC" \
  --type llc \
  --state DE \
  -j
```

Required: `--name`, `--type`, `--state`. Optional: `--ein`, `--address`, `--phone`.

Run `rightdocuments catalog -j` to enumerate the valid `--type` and `--state` values (and any other server-defined choices). Always fetch this first rather than assuming hardcoded lists — the server is the source of truth.

The JSON response includes the new entity's `id` — capture it for subsequent calls:

```sh
ENTITY_ID=$(rightdocuments entities:create --name "Acme Holdings, LLC" --type llc --state DE -j | jq -r '.entity.id // .id')
```

### 3. Import documents into the entity

`import` uploads a PDF as an executed document attached to the entity:

```sh
rightdocuments import ./formation-certificate.pdf --entity "$ENTITY_ID" -j
rightdocuments import ./operating-agreement.pdf  --entity "$ENTITY_ID" -j
```

Each import returns the new document's metadata (id, name, urls). Repeat for every PDF you want attached.

### 4. Verify

```sh
rightdocuments documents "$ENTITY_ID" -j | jq '.documents[] | {id, name}'
```

Lists every document on the entity. Without `-j` you get a tab-separated `id<TAB>name` list, easier on the eye.

## Command reference

| Command | Purpose | Key options |
|---|---|---|
| `login` | Start OAuth device flow | — |
| `logout` | Clear token | — |
| `whoami` | Show current user/org | `-j` |
| `entities` | List entities you can access | `-j` |
| `entities:info <entity_id>` | Show one entity by ID | `-j` |
| `entities:create` | Create an entity | `--name`, `--type`, `--state`, `--ein`, `--address`, `--phone`, `-j` |
| `documents <entity_id>` | List documents on an entity | `-j` |
| `import <path> --entity <id>` | Upload a PDF as an executed document | `-j` |
| `catalog` | Enumerate server-defined choices (entity types, states, statuses) | `-j` |
| `skills` | Print this guide (for agents/LLMs) | — |

## Tips for agentic use

- **Always pass `-j`** when you intend to parse output; the human-readable format is unstable.
- **Capture IDs immediately** with `jq -r`. The entity/document `id` fields are UUIDs you'll need for subsequent calls.
- **Errors are non-zero exit code + a single line** like `entities:create failed: HTTP 422 — {"error":...}`. Parse the JSON body after the em-dash for actionable detail.
- **Re-authenticate when 401**: a stale or rotated token surfaces as `HTTP 401`. Run `rightdocuments login` and retry.
- **Profiles**: each login is bound to one organization. If the user works in more than one organization, pass the same `--profile NAME` on every call (or set `RIGHTDOCUMENTS_PROFILE`). `rightdocuments profiles -j` lists the stored logins with their organizations; check it before you write data.

## Reading stored files

`documents:info ID -j` lists every stored file of a document in `document.files`: `key` (`executed`, `unsigned`, `certificate`, `original`, or an asset key), `filename`, `byte_size`, `checksum`. `original` is the raw upload before letterhead; `certificate` is the signing certificate. The asset with `filed_copy: true` (also `document.filed_copy`) is the stamped copy that the user marked as filed; download it with the key `filed`. `documents:download` without a file takes the filed copy first, then `executed`, then `unsigned`.

```sh
rightdocuments documents:info DOC_ID -j | jq '.document.files[] | {key, filename, byte_size}'
rightdocuments documents:download DOC_ID                 # executed (else unsigned) into the current directory
rightdocuments documents:download DOC_ID original -o /tmp/scan.pdf
rightdocuments documents:download DOC_ID --all -o ./doc-files/
rightdocuments documents:download DOC_ID --stdout | pdftotext - -
```

Downloads are checked against the server's MD5; a mismatch fails and saves nothing. Existing files are not overwritten without `-f`.

## Clients

A client has a number (`0004`) that the server assigns on creation. Commands accept the number (`4` or `0004`), the exact name, or the UUID. New clients are `prospective`.

```sh
rightdocuments clients -j                                   # all clients; filter with --status, --type
rightdocuments clients:create --name "Cheers, Inc." --type business \
  --email sam@example.com --entity "Cheers, Inc." -j        # --entity links one of our companies
rightdocuments clients:info 4 -j                            # contact fields, company, counts
rightdocuments clients:update 4 --status engaged -j         # organization admins only
rightdocuments clients:delete 4 --yes                       # organization admins; fails if it has matters
```

The engagement date (`engaged_at`) cannot be set here: an executed engagement letter sets it.

## Matters: client-matter work (letters, demands, lawsuits)

A matter is one piece of work for a client. Its number is `CLIENT-SEQUENCE`, e.g. `0004-001` (client 4, its first matter). The server assigns it on creation and it never changes. Commands accept the number (`0004-001` or `4-1`) or the UUID.

```sh
rightdocuments clients -j                                   # find the client number
rightdocuments matters:create --client 4 --name "Malone v. Olde Towne Tavern" -j
rightdocuments matters:update 0004-001 --type pre_litigation --role claimant \
  --description "Trademark notice to the rival bar" -j
rightdocuments parties:add 0004-001 --name "Gary's Olde Towne Tavern" \
  --role adverse_party --address "123 Main St\nBoston, MA" -j
rightdocuments import notice.pdf --matter 0004-001 --name "Notice of dispute" -j
rightdocuments matters:info 0004-001 -j                     # settings, parties, document count
```

- New matters open with status `open`, opened today, and no type. Set the rest with `matters:update`.
- `--type`: `advisory`, `pre_litigation`, `litigation`. `--role`: `plaintiff`, `defendant`, `claimant`, `respondent`, `advisor`. `--status`: `open`, `closed`.
- Party `--role`: `adverse_party` (default), `opposing_counsel`, `co_counsel`, `court`, `witness`, `other`. Use `--entity` when the party is one of the organization's companies.
- `import --matter` files the PDF under the matter; the document belongs to the matter's client. Give exactly one of `--entity` or `--matter`.

## Removing a document: void first

Deleting is two steps, as in the web app. `documents:void ID` hides the document from lists and checklists (the creator or an admin can do it). `documents:restore ID` undoes it. `documents:delete ID` removes it permanently, only for admins and only after it is voided; otherwise the server answers 409 "Void the document first".

## Deadlines on a matter

A deadline is a date something must happen by: a response window, a filing date, the statute of limitations. A person marks it done; it is not satisfied by a document. Overdue and soon-due deadlines (14 days) of open matters appear under "Needs me" on the web Home page.

```sh
rightdocuments deadlines:add 0004-001 --name "Tavern names a representative" --due 2026-09-16 \
  --notes "14 days from the notice of Sep 2" -j
rightdocuments deadlines 0004-001 -j          # by due date, with state: overdue, due_soon, upcoming, done
rightdocuments deadlines:done 0004-001 DEADLINE_ID
rightdocuments deadlines:reopen 0004-001 DEADLINE_ID
rightdocuments deadlines:remove 0004-001 DEADLINE_ID
```

## Logging how a document was sent

Record each send so the matter has a paper trail. `--party` takes a party ID of the document's matter (see `parties MATTER -j`) and fills the recipient's name, address and email.

```sh
rightdocuments deliveries:add DOCUMENT_ID --channel mail --sent 2026-09-02 \
  --party PARTY_ID --notes "USPS First Class, certified, return receipt" -j
rightdocuments deliveries:add DOCUMENT_ID --channel email --to "Gary" --email gary@example.com -j
rightdocuments deliveries DOCUMENT_ID -j
rightdocuments deliveries:update DOCUMENT_ID DELIVERY_ID --status delivered --delivered 2026-09-08
```

Channels: `email`, `mail`, `courier`, `hand`, `other`. Mail and courier need an address (or `--party`); email needs `--email`. Logging is refused (409) on a voided document.

## Possible conflicts of interest

`matters:info` (and the JSON's `conflicts` array) lists adverse parties or opposing counsel whose names match one of the organization's clients or companies, or a party linked to one of our companies. It is a name match only; tell the user and let a lawyer decide.

## Mailing a letter

`documents:mail` mails a document (on a matter) to one of the matter's parties as a printed letter: USPS First Class, certified with return receipt by default. **It sends a real, paid letter.** Never run it without the user's explicit go-ahead for that specific letter; the CLI refuses without `--yes`. The organization's mailing address must be set in the web app (Edit Organization → Mailing address).

```sh
rightdocuments documents:mail DOCUMENT_ID --party PARTY_ID --service certified_return_receipt --yes -j
rightdocuments deliveries:sync DOCUMENT_ID DELIVERY_ID -j   # pull USPS tracking (also runs daily)
rightdocuments deliveries DOCUMENT_ID                       # shows tracking number and last event
```

