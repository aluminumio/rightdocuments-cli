# RightDocuments CLI — Skill

Drive the RightDocuments API from the shell. The CLI is `rightdocuments` (installed via `brew install aluminumio/tap/rightdocuments`). All data commands accept `-j`/`--json` for machine-readable output — prefer this when piping or parsing.

## Authentication

```sh
rightdocuments login        # OAuth device flow; opens a code URL the user must visit
rightdocuments whoami -j    # confirms current user + organization
rightdocuments logout       # clears stored token (~/.netrc)
```

The token is persisted in `~/.netrc` under the `app.rightdocuments.com` machine. Override the host with `RIGHTDOCUMENTS_URL` (e.g. `http://localhost:3000` for dev).

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

Valid `--type` values: `c-corp`, `s-corp`, `llc`, `partnership`.
Valid `--state` values: `CA`, `DE`.

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
| `entities:create` | Create an entity | `--name`, `--type`, `--state`, `--ein`, `--address`, `--phone`, `-j` |
| `documents <entity_id>` | List documents on an entity | `-j` |
| `import <path> --entity <id>` | Upload a PDF as an executed document | `-j` |
| `skills` | Print this guide (for agents/LLMs) | — |

## Tips for agentic use

- **Always pass `-j`** when you intend to parse output; the human-readable format is unstable.
- **Capture IDs immediately** with `jq -r`. The entity/document `id` fields are UUIDs you'll need for subsequent calls.
- **Errors are non-zero exit code + a single line** like `entities:create failed: HTTP 422 — {"error":...}`. Parse the JSON body after the em-dash for actionable detail.
- **Re-authenticate when 401**: a stale or rotated token surfaces as `HTTP 401`. Run `rightdocuments login` and retry.
- **Override the API host** via `RIGHTDOCUMENTS_URL` for dev/staging. The token stored in `~/.netrc` is keyed by host, so you can keep dev and prod tokens side-by-side.
