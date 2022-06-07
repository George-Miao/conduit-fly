# syntax=docker/dockerfile:1
FROM docker.io/rust:1.58-bullseye AS builder
WORKDIR /usr/src/conduit

# Install required packages to build Conduit and it's dependencies
RUN apt-get update && \
    apt-get -y --no-install-recommends install libclang-dev=1:11.0-51+nmu5

# == Build dependencies without our own code separately for caching ==
#
# Need a fake main.rs since Cargo refuses to build anything otherwise.
#
# See https://github.com/rust-lang/cargo/issues/2644 for a Cargo feature
# request that would allow just dependencies to be compiled, presumably
# regardless of whether source files are available.
RUN mkdir src && touch src/lib.rs && echo 'fn main() {}' > src/main.rs
COPY Cargo.toml Cargo.lock ./
RUN cargo build --release && rm -r src

# Copy over actual Conduit sources
COPY src src

# main.rs and lib.rs need their timestamp updated for this to work correctly since
# otherwise the build with the fake main.rs from above is newer than the
# source files (COPY preserves timestamps).
#
# Builds conduit and places the binary at /usr/src/conduit/target/release/conduit
RUN touch src/main.rs && touch src/lib.rs && cargo build --release

# ---------------------------------------------------------------------------------------------------------------
# Stuff below this line actually ends up in the resulting docker image
# ---------------------------------------------------------------------------------------------------------------
FROM docker.io/debian:bullseye-slim AS runner

# Standard port on which Conduit launches.
# You still need to map the port when using the docker command or docker-compose.
EXPOSE 6167

ENV CONDUIT_PORT=6167 \
    CONDUIT_ADDRESS="0.0.0.0" \
    CONDUIT_DATABASE_PATH=/var/lib/matrix-conduit \
    CONDUIT_CONFIG=''
#    └─> Set no config file to do all configuration with env vars

# Conduit needs:
#   ca-certificates: for https
#   iproute2 & wget: for the healthcheck script
RUN apt-get update && apt-get -y --no-install-recommends install \
    ca-certificates \
    iproute2 \
    wget \
    && rm -rf /var/lib/apt/lists/*

# Created directory for the database and media files
RUN mkdir -p /srv/conduit/.local/share/conduit

# Test if Conduit is still alive, uses the same endpoint as Element
COPY ./docker/healthcheck.sh /srv/conduit/healthcheck.sh
HEALTHCHECK --start-period=5s --interval=5s CMD ./healthcheck.sh

# Copy over the actual Conduit binary from the builder stage
COPY --from=builder /usr/src/conduit/target/release/conduit /srv/conduit/conduit

# Make the healthcheck executable:
RUN chmod +x /srv/conduit/healthcheck.sh

# Set container home directory
WORKDIR /srv/conduit

# Run Conduit and print backtraces on panics
ENV RUST_BACKTRACE=1
ENTRYPOINT [ "/srv/conduit/conduit" ]
