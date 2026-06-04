# syntax=docker/dockerfile:1

# ---------------------------------------------------------------------------
# Build stage: compile this thin customization layer against the *published*
# feedletter artifact and assemble a single runnable fat-jar.
#
# Nothing of feedletter itself is built from source here -- `com.mchange::feedletter`
# is pulled as a binary dependency (see build.mill). Only your untemplates (untemplate/)
# and customizers (src/) are compiled, so rebuilds after a customization change are small.
# ---------------------------------------------------------------------------
FROM eclipse-temurin:21-jdk AS build

# The bundled ./mill launcher bootstraps itself over the network and needs curl.
RUN apt-get update && apt-get install -y --no-install-recommends curl && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# 1) Resolve dependencies in their own layer, keyed only on the build definition.
#    Editing untemplates/customizers below will NOT invalidate this layer, so the
#    (large) feedletter + ZIO/Tapir/Netty download is fetched once and reused.
COPY mill mill-update build.mill ./
RUN ./mill resolvedRunMvnDeps

# 2) Copy the customization sources and assemble. This is the only layer that
#    rebuilds when you change look-and-feel.
COPY . .
RUN ./mill assembly

# ---------------------------------------------------------------------------
# Runtime stage: a slim JRE running the assembled jar as PID 1.
# ---------------------------------------------------------------------------
FROM eclipse-temurin:21-jre AS run

# A terminal editor for interactive admin commands. `edit-subscribable` shells
# out to $EDITOR on a temp file, so the editor binary must exist IN THE IMAGE
# (a host-side EDITOR is invisible to the container). nano is the friendly
# default; swap for vim-tiny if you prefer.
RUN apt-get update && apt-get install -y --no-install-recommends nano \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=build /build/out/assembly.dest/out.jar /app/feedletter.jar
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# feedletter looks here for its secrets file (also overridable via FEEDLETTER_SECRETS).
ENV FEEDLETTER_SECRETS=/etc/feedletter/feedletter-secrets.properties

# Used by `edit-subscribable`. Harmless for the daemon, which ignores it.
ENV EDITOR=nano

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
# Default to running the service. Override for one-off admin commands, e.g.:
#   docker compose run --rm feedletter db-init
CMD ["daemon"]
