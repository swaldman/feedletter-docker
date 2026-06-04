# feedletter-docker

A containerized deployment of [feedletter](https://github.com/swaldman/feedletter) —
RSS/Atom feeds into newsletters and notifications — bundled with PostgreSQL and an
automatic-HTTPS reverse proxy.

It runs three containers via Docker Compose:

| service      | role                                                        |
|--------------|-------------------------------------------------------------|
| `db`         | PostgreSQL — the system of record                           |
| `feedletter` | the service (daemon + web API), built from this directory   |
| `caddy`      | TLS termination + reverse proxy, with automatic Let's Encrypt certs |

## How this relates to the other feedletter repos

This repo is a **thin customization layer**, structurally the same as
[`feedletter-install`](https://github.com/swaldman/feedletter-install): it depends on
the *published* `com.mchange::feedletter` artifact (see `build.mill`) rather than
building feedletter from source. Only your own untemplates (`untemplate/`) and
customizers (`src/`) are compiled — into a fat-jar, inside the image.

Practically, that means:

- **No customization?** A plain `docker compose up` builds and runs the defaults.
- **Customizing look-and-feel?** Drop untemplates into `untemplate/` and customizers
  into `src/`, then rebuild the image. Because dependencies live in a separate, cached
  Docker layer, these rebuilds only recompile your small layer — they're fast.

## Prerequisites

- Docker with the Compose plugin.
- For a *publicly trusted* certificate: a domain whose DNS points at this host, with
  inbound ports **80 and 443** reachable. (Without that, see "Local testing" below.)

## Setup

1. **Configure environment and secrets.**

   ```bash
   cp .env.sample .env
   cp secrets/feedletter-secrets.properties.sample secrets/feedletter-secrets.properties
   chmod 600 secrets/feedletter-secrets.properties      # REQUIRED — see note below
   ```

   Edit both files. The Postgres password must be **identical** in `.env`
   (`POSTGRES_PASSWORD`) and the secrets file (`feedletter.jdbc.password`).

2. **Build the image.**

   ```bash
   docker compose build
   ```

3. **Initialize the database** (one-off command — the `db` container starts on demand):

   ```bash
   docker compose run --rm feedletter db-init
   ```

4. **Set required configuration.** Two settings differ from a bare-metal install:

   ```bash
   # Bind the web daemon to all interfaces so the caddy container can reach it.
   # (Default is 127.0.0.1, which is unreachable from another container.)
   docker compose run --rm feedletter set-config --web-daemon-interface 0.0.0.0

   # Tell feedletter its public URL, so the links it emits are correct.
   # Use your ACTUAL domain literally here. Do NOT write "$FEEDLETTER_DOMAIN":
   # the variable in .env is read by Docker Compose, not exported into your
   # shell, so it would expand to an empty string and store an empty hostname.
   docker compose run --rm feedletter set-config \
     --web-api-protocol https \
     --web-api-host-name feedletter.example.com
   ```

5. **Add feeds and define subscribables** (examples — see `--help` for each):

   ```bash
   docker compose run --rm feedletter add-feed https://example.com/feed.xml
   docker compose run --rm feedletter define-email-subscribable --help
   ```

6. **Start the stack.** The `caddy` service is gated behind the `proxy` profile, so
   the production stack (with TLS) is started with:

   ```bash
   docker compose --profile proxy up -d
   ```

   On first start Caddy obtains a TLS certificate for `FEEDLETTER_DOMAIN`. Watch with
   `docker compose logs -f caddy`.

## Running admin commands

The image's entrypoint is the feedletter CLI, so any subcommand works as a one-off:

```bash
docker compose run --rm feedletter list-feeds
docker compose run --rm feedletter list-subscribables
docker compose run --rm feedletter export-subscribers
```

`edit-subscribable` is interactive; run it with a TTY. The image ships `nano` as
`$EDITOR`, so it opens an editor inside the container:

```bash
docker compose run --rm -it feedletter edit-subscribable
```

## Deploying changes

After editing untemplates (`untemplate/`) or customizers (`src/`), rebuild the image
and recreate the running container from it:

```bash
./rebuild-redeploy
```

That wraps `docker compose --profile proxy up -d --build` (and `cd`s to the repo first,
so it works from any directory). Note this is `up --build`, **not** `docker compose
restart`: only rebuilding the image and recreating the container picks up your changes;
`restart` would re-run the old one. Extra args are forwarded, e.g. `./rebuild-redeploy
--no-cache`.

## Why these conventions (gotchas worth knowing)

- **Secrets file permissions.** feedletter refuses to read a secrets file unless its
  permissions are `600` or `400` (it throws `LeakySecrets` otherwise). The file is
  mounted read-only into the container; set `chmod 600` on the host copy.

- **Web daemon bind interface.** feedletter defaults to binding `127.0.0.1`. Inside a
  container that is unreachable from the separate `caddy` container, so step 4 sets it
  to `0.0.0.0`. The port is *not* published to the host — only Caddy fronts it.

- **Foreground process, not a forking daemon.** Here feedletter runs as an ordinary
  foreground process — PID 1 inside its container — and its lifecycle is managed by
  Docker: the restart policy supervises it, and `docker compose down`/stop sends SIGTERM
  for a clean shutdown. This differs from the other deployment paths (e.g.
  [`feedletter-install`](https://github.com/swaldman/feedletter-install)), where
  feedletter runs as a **systemd-managed forking daemon** (`daemon --fork`, with a PID
  file). Accordingly this repo's build drops `mill-daemon` entirely, and the host
  `feedletter` wrapper has no `--fork` path.

- **Keep the `caddy_data` volume.** It holds the issued certificate and ACME account
  key. Destroying it forces re-issuance and can hit Let's Encrypt rate limits.

## Local testing (no domain, no TLS)

For experimenting on your own machine, skip Caddy entirely and reach feedletter
directly. The `docker-compose.local.yml` overlay publishes the web daemon to
`localhost:8024`; omitting `--profile proxy` keeps the `caddy` service down.

```bash
# bootstrap (same as prod, but with the local overlay and no proxy profile)
docker compose -f docker-compose.yml -f docker-compose.local.yml run --rm feedletter db-init
docker compose -f docker-compose.yml -f docker-compose.local.yml \
  run --rm feedletter set-config --web-daemon-interface 0.0.0.0
docker compose -f docker-compose.yml -f docker-compose.local.yml \
  run --rm feedletter set-config --web-api-protocol http --web-api-host-name localhost

# run it
docker compose -f docker-compose.yml -f docker-compose.local.yml up
```

Then open <http://localhost:8024/>. You still need a `.env` (any non-empty
`FEEDLETTER_DOMAIN` is fine since Caddy isn't started) and a `chmod 600` secrets
file. `--web-daemon-interface 0.0.0.0` is required even locally: the published port
forwards to the container, and the process must bind all interfaces *inside* the
container to receive it.

If instead you want to exercise the *real* TLS path locally, start with `--profile
proxy` and either set `FEEDLETTER_DOMAIN=localhost` (Caddy serves its own internal CA
cert — your browser warns unless you trust Caddy's root) or uncomment the `acme_ca`
staging line in `Caddyfile`.

## Updating feedletter

Bump the version in `build.mill` (`mvn"com.mchange::feedletter:<version>"`), then
`docker compose build && docker compose --profile proxy up -d`. Database schema
changes are applied with `docker compose run --rm feedletter db-migrate`.
