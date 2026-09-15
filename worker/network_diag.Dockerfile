# =============================================================================
# network_diag.Dockerfile
#
# Isolates the "download from api.github.com hangs ~60s then fails" problem
# from worker.Dockerfile, without paying for the full Stan/CmdStan build
# (10+ minutes) on every retry. Same base image as worker.Dockerfile, so any
# network path difference is environmental (proxy/firewall/DNS), not a base
# image quirk.
#
# Build + run (seconds, not minutes):
#   docker build --no-cache -f network_diag.Dockerfile -t netdiag .
#   docker run --rm netdiag
#
# If your host needs a proxy for internet egress, pass it through explicitly
# -- Docker build containers do NOT automatically inherit host proxy env
# vars unless you do this (or configure Docker Desktop's own proxy settings):
#   docker build --no-cache -f network_diag.Dockerfile -t netdiag \
#     --build-arg HTTP_PROXY=$HTTP_PROXY --build-arg HTTPS_PROXY=$HTTPS_PROXY \
#     --build-arg NO_PROXY=$NO_PROXY .
# =============================================================================
FROM rocker/tidyverse:latest

# Only present if passed via --build-arg above; empty otherwise (harmless).
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY
ENV HTTP_PROXY=${HTTP_PROXY}
ENV HTTPS_PROXY=${HTTPS_PROXY}
ENV NO_PROXY=${NO_PROXY}

RUN apt-get update && apt-get install -y --no-install-recommends \
      curl dnsutils iputils-ping ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Everything below is display-only diagnostics -- always exit 0 so you get
# the FULL report even if an early check fails, instead of stopping at the
# first red X the way a normal RUN chain would.
RUN set +e; \
    { \
    echo "=== env proxy vars (should be non-empty if you passed --build-arg) ==="; \
    echo "HTTP_PROXY=$HTTP_PROXY  HTTPS_PROXY=$HTTPS_PROXY  NO_PROXY=$NO_PROXY"; \
    echo; \
    echo "=== DNS resolution ==="; \
    for h in github.com api.github.com codeload.github.com; do \
      echo "--- $h ---"; getent hosts "$h" || echo "DNS FAILED for $h"; \
    done; \
    echo; \
    echo "=== TCP connect on 443 (5s timeout each) ==="; \
    for h in github.com api.github.com codeload.github.com; do \
      echo -n "$h:443 -> "; \
      timeout 5 bash -c "echo > /dev/tcp/$h/443" 2>/dev/null && echo OK || echo "TIMED OUT / REFUSED"; \
    done; \
    echo; \
    echo "=== curl -v HEAD on the exact tarball URL that fails in the real build (15s timeout) ==="; \
    timeout 15 curl -v -I --max-time 12 \
      "https://api.github.com/repos/immunoplex/curveRcore/tarball/v0.4.2" \
      2>&1 | tail -40; \
    echo; \
    echo "=== curl -v HEAD on plain github.com (control -- does ANY github host work?) ==="; \
    timeout 15 curl -v -I --max-time 12 "https://github.com" 2>&1 | tail -20; \
    echo; \
    echo "=== curl timing breakdown (dns/connect/tls/total) on the failing URL ==="; \
    curl -o /dev/null -s --max-time 12 -w \
      "dns_resolve=%{time_namelookup}s connect=%{time_connect}s tls_handshake=%{time_appconnect}s total=%{time_total}s http_code=%{http_code}\n" \
      "https://api.github.com/repos/immunoplex/curveRcore/tarball/v0.4.2" \
      || echo "curl itself failed/timed out -- see verbose block above for where"; \
    echo; \
    echo "=== FULL DOWNLOAD, following redirect to codeload.github.com (this is what remotes::install_github() actually does -- a HEAD/-I request stops at the redirect and never exercises this path) ==="; \
    curl -L -o /tmp/tarball.tar.gz -s --max-time 90 -w \
      "dns_resolve=%{time_namelookup}s connect=%{time_connect}s tls_handshake=%{time_appconnect}s total=%{time_total}s http_code=%{http_code} size_bytes=%{size_download}\n" \
      "https://api.github.com/repos/immunoplex/curveRcore/tarball/v0.4.2"; \
    echo "exit code: $?"; \
    ls -la /tmp/tarball.tar.gz 2>/dev/null || echo "no file written -- download did not complete"; \
    echo; \
    echo "=== DONE -- read from the top; first failing section tells you the layer ==="; \
    } > /diag.log 2>&1; \
    cat /diag.log

# rocker/tidyverse's own image sets an ENTRYPOINT that launches RStudio
# Server via s6-init -- override BOTH entrypoint and cmd so `docker run` just
# reprints the report captured above instead of starting a server that
# looks like it's "sitting there" doing nothing.
ENTRYPOINT []
CMD ["cat", "/diag.log"]
