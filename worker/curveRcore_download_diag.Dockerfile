# =============================================================================
# curveRcore_download_diag.Dockerfile
#
# Focused on: can curveRcore@v0.4.2 specifically be reliably downloaded and
# installed from GitHub? Bandwidth throttling was ruled out (faster network,
# still failing), so this checks three different things that could each look
# like "download failed":
#   1. Is the tarball itself consistent/uncorrupted across repeated fetches?
#      (repeated download + gzip integrity + checksum comparison)
#   2. Does an entirely different transport (git smart-HTTP clone) succeed
#      where the tarball API path fails? Narrows it to "something about the
#      tarball/codeload path" vs "something about reaching GitHub at all."
#   3. Does the REAL remotes::install_github() call fail differently now
#      that timeout isn't the constraint -- with the actual R-level error
#      printed in full, not just "download failed."
#
# Build + run (should take well under a minute, no Stan/CmdStan involved):
#   docker build --no-cache -f worker/curveRcore_download_diag.Dockerfile -t coredl . 2>&1 | tee coredl_output.txt
# =============================================================================
FROM rocker/tidyverse:latest

RUN apt-get update && apt-get install -y --no-install-recommends \
      curl git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

ARG CURVERCORE_REF=v0.4.2

RUN set +e; \
    { \
    echo "=== 0. confirm the tag exists on the remote and what commit it peels to ==="; \
    git ls-remote --tags https://github.com/immunoplex/curveRcore.git "${CURVERCORE_REF}" "${CURVERCORE_REF}^{}"; \
    echo; \
    \
    echo "=== 1. repeated tarball download (3x) via the exact URL remotes::install_github() uses ==="; \
    echo "     checking: does it complete every time, and is the content IDENTICAL each time?"; \
    URL="https://api.github.com/repos/immunoplex/curveRcore/tarball/${CURVERCORE_REF}"; \
    for i in 1 2 3; do \
      echo "--- attempt $i ---"; \
      START=$(date +%s); \
      curl -L -o "/tmp/tarball_$i.tar.gz" -s --max-time 120 -w \
        "  http_code=%{http_code} size_bytes=%{size_download} total_time=%{time_total}s\n" \
        "$URL"; \
      RC=$?; \
      END=$(date +%s); \
      echo "  curl exit code: $RC   wall time: $((END-START))s"; \
      if [ -f "/tmp/tarball_$i.tar.gz" ]; then \
        echo -n "  gzip integrity: "; gzip -t "/tmp/tarball_$i.tar.gz" 2>&1 && echo OK; \
        echo "  md5sum: $(md5sum /tmp/tarball_$i.tar.gz)"; \
        echo "  tar contents (first 5 entries): "; \
        tar -tzf "/tmp/tarball_$i.tar.gz" 2>&1 | head -5; \
      else \
        echo "  NO FILE WRITTEN"; \
      fi; \
      echo; \
    done; \
    echo "--- comparing all 3 checksums (should be 3 identical lines if the tarball is stable) ---"; \
    md5sum /tmp/tarball_*.tar.gz 2>/dev/null; \
    echo; \
    \
    echo "=== 2. alternate transport: git clone --depth 1 --branch (bypasses tarball API entirely) ==="; \
    START=$(date +%s); \
    timeout 60 git clone --depth 1 --branch "${CURVERCORE_REF}" \
      https://github.com/immunoplex/curveRcore.git /tmp/core_clone 2>&1; \
    RC=$?; \
    END=$(date +%s); \
    echo "  git clone exit code: $RC   wall time: $((END-START))s"; \
    if [ -f /tmp/core_clone/DESCRIPTION ]; then \
      echo "  DESCRIPTION found. Version line:"; \
      grep '^Version:' /tmp/core_clone/DESCRIPTION; \
    else \
      echo "  DESCRIPTION NOT FOUND -- clone did not produce a usable package dir"; \
    fi; \
    echo; \
    \
    echo "=== 3. the REAL remotes::install_github() call, default timeout, FULL error detail ==="; \
    R -e "options(timeout = 300); \
          if (!requireNamespace('remotes', quietly = TRUE)) install.packages('remotes', repos='https://cloud.r-project.org/'); \
          tryCatch({ \
            remotes::install_github('immunoplex/curveRcore@${CURVERCORE_REF}', upgrade='never', force=TRUE); \
            cat('SUCCESS: curveRcore', as.character(packageVersion('curveRcore')), 'installed\n'); \
          }, error = function(e) { \
            cat('FAILURE. Full condition object:\n'); \
            print(e); \
            cat('\nclass(e):', paste(class(e), collapse=', '), '\n'); \
          })" 2>&1; \
    echo; \
    echo "=== DONE ==="; \
    } > /diag.log 2>&1; \
    cat /diag.log

ENTRYPOINT []
CMD ["cat", "/diag.log"]
