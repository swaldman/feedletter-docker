#!/usr/bin/env bash
set -euo pipefail

# Run the assembled feedletter jar, forwarding all arguments to its CLI.
#
# `exec` replaces this shell so the JVM becomes PID 1 and receives SIGTERM
# directly when the container stops -- giving feedletter a clean shutdown
# (connection pool drained, in-flight work finished) rather than a hard kill.
#
# JAVA_OPTS lets a deployer tune the JVM (heap, GC, etc.) without rebuilding.
exec java ${JAVA_OPTS:-} -jar /app/feedletter.jar "$@"
