# gbrain-server

Deployment wrapper for [gbrain](https://github.com/garrytan/gbrain) as the
Gravitas company brain. Runs the HTTP/MCP server at `https://brain.shazan.me`.

This repo holds **infrastructure only** — no knowledge, no secrets. The brain
content is the private [`gravitas-brain`](https://github.com/shazanjustin/gravitas-brain)
repo, cloned at boot with a read-only deploy key.

## Why the install looks the way it does

`bun install -g github:garrytan/gbrain` **does not work here.** Bun blocks
gbrain's top-level postinstall on global installs (upstream
[#218](https://github.com/garrytan/gbrain/issues/218)), so the PGLite WASM asset
is never unpacked and the first `gbrain init` dies with:

```
Cannot find module '../../node_modules/@electric-sql/pglite/dist/pglite.wasm'
```

The Dockerfile uses upstream's documented fallback — `git clone` + `bun link` —
which is the only path verified to produce a working brain on this image.

## Environment

| Variable | Required | Purpose |
|---|---|---|
| `GBRAIN_ADMIN_BOOTSTRAP_TOKEN` | yes | Admin login for `/admin`. **Must be ≥32 chars, `[A-Za-z0-9_-]+`** — the server refuses to start otherwise. Set it explicitly: on a non-TTY start the auto-generated token is hidden so it never lands in log storage. |
| `GBRAIN_PUBLIC_URL` | yes | Public origin. Must match what clients actually hit, or OAuth discovery advertises the wrong issuer and every client fails at the token step (RFC 8414 §3.3). |
| `BRAIN_REPO_URL` | yes | SSH URL of the private brain repo. |
| `BRAIN_DEPLOY_KEY` | yes | Read-only ed25519 deploy key for that repo, newlines escaped as `\n`. |
| `OPENAI_API_KEY` | no | Embeddings, query expansion, chat. Without it the brain runs keyword-only. |
| `GBRAIN_SEARCH_MODE` | no | `conservative` \| `balanced` \| `tokenmax`. Default `balanced`. |
| `GBRAIN_DREAM_ON_BOOT` | no | `1` runs the overnight maintenance cycle at boot. Off by default — `dream` is LLM-bearing and bills per run. |
| `GBRAIN_BIND` | no | Default `0.0.0.0`. **Do not set to `127.0.0.1`** — upstream changed the default bind in v0.34.1, and loopback-only presents as a proxy 502 against a perfectly clean application log. |

## Persistence

`GBRAIN_HOME=/data` puts the brain at `/data/.gbrain`. **`/data` must be on a
Coolify volume.** If it isn't, every redeploy silently wipes the brain while the
service still looks healthy. The entrypoint prints which case it's in at boot:

```
data dir: /data (on a mount, persists across redeploys)          # good
data dir: /data -- EPHEMERAL, not on any mount; ... WILL be wiped # volume missing
```

## The PGLite single-process constraint

PGLite holds an exclusive lock, so `gbrain serve` and any `gbrain` CLI command
cannot open the brain simultaneously:

> This brain uses PGLite, so a separate CLI process cannot open it at the same time.

That rules out running `gbrain sync` / `gbrain dream` on a cron alongside the
server. The only safe maintenance window is at boot, before `exec gbrain serve`
— which is what the entrypoint does. **A nightly container restart is therefore
the maintenance schedule.** If this ever becomes limiting, the fix is migrating
to the Postgres engine (`gbrain migrate --to`), where multiple processes can
connect; upstream considers Postgres the right engine past ~7K pages.

## The markdown is the source of truth

The PGLite index is derived from the brain repo and can always be rebuilt with
`gbrain sync`. Losing the volume costs the index, not the knowledge.
