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
  inbound ports **80 and 443** reachable. (If you terminate TLS elsewhere, see
  "Running behind your own TLS / reverse proxy" below.)

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

5. **Generate the starter email templates, and bake them in.** Do this **before**
   defining any email subscribable — it's what your newsletters will be styled from:

   ```bash
   docker compose run --rm -v "$PWD/untemplate:/app/untemplate" feedletter generate-starter-untemplates
   docker compose build      # compile the scaffolded templates into the image
   ```

   This writes editable copies of feedletter's default email untemplates (including
   `style.css.untemplate`) to `untemplate/local/subscription/email/`, then bakes them into
   the image. Email subscribables you define from here on **bind to these local templates**,
   so you can restyle later just by editing them and running `./rebuild-redeploy` — no need
   to touch your subscriptions. (Order matters: a subscribable defined *before* this step
   binds to the built-in templates instead, and you'd have to switch it afterward with
   `set-untemplates`.) You can edit the templates now or anytime later — see "Styling
   untemplates" below.

6. **Add feeds and define subscribables** (examples — see `--help` for each). Because of the
   previous step, your email subscribables bind to your editable local templates:

   ```bash
   docker compose run --rm feedletter add-feed https://example.com/feed.xml
   docker compose run --rm feedletter define-email-subscribable --help
   ```

7. **Start the stack.**

   ```bash
   docker compose up -d
   ```

   This brings up all three services (db + feedletter + caddy). On first start Caddy
   obtains a TLS certificate for `FEEDLETTER_DOMAIN`; watch with
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

That wraps `docker compose up -d --build` (and `cd`s to the repo first,
so it works from any directory). Note this is `up --build`, **not** `docker compose
restart`: only rebuilding the image and recreating the container picks up your changes;
`restart` would re-run the old one. Extra args are forwarded, e.g. `./rebuild-redeploy
--no-cache`.

## Customizing the email templates

Your editable email templates live in `untemplate/local/subscription/email/` — the starter
set you scaffolded in **Setup (step 5)**. They're verbatim copies of this feedletter
version's defaults (including `style.css.untemplate`, the main styling lever), extracted
from the jar, so there's nothing to keep in sync by hand. To customize:

1. Edit the untemplates (preview them live with `./feedletter-style-docker`, below).
2. Redeploy with `./rebuild-redeploy`.

Because your subscribables were defined against these `local.subscription.email.*`
templates, edits take effect on redeploy **without redefining any subscription**.

If you skipped the Setup scaffolding step, run it now and rebuild:

```bash
docker compose run --rm -v "$PWD/untemplate:/app/untemplate" feedletter generate-starter-untemplates
./rebuild-redeploy
```

`generate-starter-untemplates` never clobbers your work — it skips files you've already
created and aborts if one would differ — so re-running it (e.g. after a feedletter upgrade,
to pick up newly added templates) is safe. One caveat: any subscribable you defined
*before* scaffolding stays bound to the built-in templates; point it at the local versions
with `set-untemplates`.

## Styling untemplates (live preview)

For the fast edit-view cycle when designing untemplates, use `./feedletter-style-docker` — the
containerized equivalent of `feedletter-style`. It starts an on-demand `style` service
that bind-mounts your `untemplate/` and `src/` and watches them with Mill (`-w`):
every save recompiles and restarts a preview server, so you just refresh the browser.

```bash
./feedletter-style-docker compose-single --subscribable-name my-list
```

Pass any `feedletter-style` subcommand (`compose-single`, `compose-multiple`, `confirm`,
`status-change`, `removal-notification`); `./feedletter-style-docker --help` lists them. It renders
against the **real database**, so the named subscribable must already be defined, and it
will start `db` if it isn't running. Ctrl-C stops it (the container is removed on exit).

The preview is served at `http://127.0.0.1:8080/`. On a **remote** server, tunnel it to
your laptop first (the port is bound to the server's loopback, not exposed to the
network):

```bash
ssh -L 8080:127.0.0.1:8080 you@server     # then browse http://localhost:8080/
```

Notes:
- The `style` service is **profile-gated** (`profiles: ["style"]`), so it never starts
  with `docker compose up` — only `./feedletter-style-docker` (which adds `--profile style`) runs it.
- It builds from the toolchain (`build`) stage, so the first run compiles; subsequent
  recompiles are incremental and fast.
- This is the live *serve* preview. Don't pass `--from/--to` to it — under `-w` a mail
  destination would re-send on every edit.
- When you're happy with the look, bake it into the running service with
  `./rebuild-redeploy`.

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

## Running behind your own TLS / reverse proxy

The default stack terminates TLS with the bundled Caddy service. If your server
already has its own TLS terminator (nginx, Traefik, a cloud load balancer, etc.),
you can run feedletter without Caddy and let that proxy front it. In
`docker-compose.yml`:

1. **Comment out the entire `caddy:` service.**
2. **Uncomment the `ports:` block under `feedletter`** so the web daemon is published
   on the host loopback for your proxy to reach. The host-side port is set by
   `FEEDLETTER_HTTP_PORT` in `.env` (default `8024`); choose one that doesn't collide
   with anything else on the host. (Only the host side is configurable — the container
   side stays `8024`, feedletter's `web-daemon-port`. This binds to `127.0.0.1`, the
   *host's* loopback, so the port is reachable only by a proxy on the same machine.)

Then point feedletter at its public URL and bind all interfaces inside the container
(the published port forwards to the container, so the process must listen on
`0.0.0.0`, not `127.0.0.1`):

```bash
docker compose run --rm feedletter set-config --web-daemon-interface 0.0.0.0
docker compose run --rm feedletter set-config \
  --web-api-protocol https --web-api-host-name your.domain.example
docker compose up -d
```

Configure your external proxy to forward to `127.0.0.1:${FEEDLETTER_HTTP_PORT}`. This
same setup (minus TLS) also serves a quick domainless trial: leave the protocol as
`http`, set the host name to `localhost`, and reach feedletter directly at
<http://localhost:8024/> (or whatever port you chose).

## Updating feedletter

Bump the version in `build.mill` (`mvn"com.mchange::feedletter:<version>"`), then
`./rebuild-redeploy` (or `docker compose up -d --build`). Database schema changes are
applied with `docker compose run --rm feedletter db-migrate`.
