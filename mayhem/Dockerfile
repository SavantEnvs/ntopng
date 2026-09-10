# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile for ntopng (OSS-Fuzz port) — builds ON TOP of the org C/C++ base image
# (ghcr.io/savantenvs/base). The base provides debian + clang/llvm + libFuzzer + the
# identities + the build-contract ENV; this only adds the per-commit ntopng build.
#
# Build (from the repo root):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) \
#       [--build-arg SOURCE_DATE_EPOCH=$(date +%s)] \
#       -t ntopng-commit:test .

FROM ghcr.io/savantenvs/base:20260621

ARG COMMIT
ARG REPO_URL
# SOURCE_DATE_EPOCH stays an ARG (available to build.sh); never bake it as ENV — an empty value
# breaks clang. build.sh unsets it when empty.
ARG SOURCE_DATE_EPOCH

# Sanitizer override: the base exports SANITIZER_FLAGS (ASan+UBSan, halting) as the default.
# Declare it WITHOUT a default so an unset arg lets the base ENV flow through; --build-arg overrides.
ARG SANITIZER_FLAGS
ARG MAYHEM_JOBS=

# ntopng builds with autotools and requires nDPI as a peer SOURCE directory (../nDPI, i.e. /nDPI
# since the ntopng tree lands at /mayhem): ntopng's own configure.ac.in looks for
# ../nDPI/src/lib/libndpi.a and, if missing, builds it itself — it never `make install`s nDPI
# system-wide. So nDPI is fetched+compiled HERE (root, at image-build time, network available)
# and never touched again by mayhem/build.sh (which must be able to re-run under --network none).
USER root
RUN [ -n "${SOURCE_DATE_EPOCH:-}" ] && repro-sources-list.sh || true
RUN apt-get update && apt-get install -yq --no-install-recommends \
      autoconf automake libtool pkg-config zip \
      libzmq3-dev libpcap-dev libjson-c-dev libmaxminddb-dev libxml2-dev \
      libsqlite3-dev flex bison libcurl4-openssl-dev librrd-dev \
      protobuf-compiler libprotobuf-dev ca-certificates git && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /
# ntopng tracks nDPI's dev branch UNPINNED (its own .github/workflows/build.yml clones nDPI HEAD),
# so the correct nDPI for a given ntopng revision is "whatever dev HEAD was at that commit". We must
# pin one anyway — the build has to be re-runnable and air-gapped — so the pin moves in lockstep with
# the ntopng revision under build, and is the nDPI dev HEAD contemporaneous with it:
#   ntopng 52c5cd878e (2026-09-14 17:07) -> nDPI f9daaf170d (2026-09-14 10:34).
# This revision DOES follow the two nDPI API breaks the previous pin sat behind — 1f2606902 (license_type
# arg on ndpi_init_detection_module) and 61337dad1 (ndpi_flow_struct split into core + metadata) — so the
# pin must be at/after them; the old da7b5101b pin fails to compile src/Flow.cpp against this ntopng.
RUN git init -q /nDPI && cd /nDPI && \
    git remote add origin https://github.com/ntop/nDPI.git && \
    git fetch -q --depth 1 origin f9daaf170d4451fae0223fd3c3d9692ae41c12eb && \
    git checkout -q FETCH_HEAD && \
    ./autogen.sh && ./configure && make -j"$(nproc)" && \
    chown -R 2000:2000 /nDPI
USER mayhem

# Source enters from the build CONTEXT (the CI checkout): the FULL repo (incl. .git history)
# is copied to /mayhem as `mayhem`; build.sh builds in place.
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

RUN bash mayhem/build.sh

# Run ntopng's functional suite at build time (a failing suite fails the image build).
RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
