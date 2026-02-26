# Stage 1: Build @atproto/pds from our fork
FROM node:20.20-alpine3.23 AS atproto-build

RUN corepack enable
RUN apk add --no-cache git python3 make g++

WORKDIR /atproto
# Clone the fork — use ARG so CI can override the branch
# CACHE_BUST arg invalidates the clone layer when the upstream repo changes
ARG ATPROTO_BRANCH=main
ARG CACHE_BUST=1
RUN git clone --depth 1 --branch ${ATPROTO_BRANCH} https://github.com/grishaLR/atproto.git .
RUN corepack prepare --activate
RUN pnpm install --no-frozen-lockfile
RUN pnpm --filter @atproto/pds... run build
# Pack the PDS package as a tarball for the service stage
RUN cd packages/pds && pnpm pack --pack-destination /tmp

# Stage 2: Build goat + service
FROM node:20.20-alpine3.23 AS build

RUN corepack enable

# Build goat binary
ENV CGO_ENABLED=0
ENV GODEBUG="netdns=go"
WORKDIR /tmp
RUN apk add --no-cache git go
RUN git clone https://github.com/bluesky-social/goat.git && cd goat && git checkout v0.2.2 && go build -o /tmp/goat-build .

# Move files into the image and install
WORKDIR /app
COPY ./service ./

# Replace the npm version with our fork's tarball
COPY --from=atproto-build /tmp/atproto-pds-*.tgz /tmp/
RUN TARBALL=$(ls /tmp/atproto-pds-*.tgz | head -1) && \
    cat package.json | sed "s|\"@atproto/pds\": \".*\"|\"@atproto/pds\": \"file:${TARBALL}\"|" > package.json.tmp && \
    mv package.json.tmp package.json && \
    rm -f pnpm-lock.yaml

RUN corepack prepare --activate
RUN pnpm install --production > /dev/null

# Stage 3: Final image with Litestream
FROM node:20.20-alpine3.23

RUN apk add --update dumb-init sqlite bash curl rclone

# Add Litestream for continuous SQLite backup to R2
ADD https://github.com/benbjohnson/litestream/releases/download/v0.3.13/litestream-v0.3.13-linux-amd64.tar.gz /tmp/litestream.tar.gz
RUN tar -xzf /tmp/litestream.tar.gz -C /usr/local/bin/ && rm /tmp/litestream.tar.gz

# Avoid zombie processes, handle signal forwarding
ENTRYPOINT ["dumb-init", "--"]

WORKDIR /app
COPY --from=build /app /app
COPY --from=build /tmp/goat-build /usr/local/bin/goat
COPY litestream-base.yml /etc/litestream-base.yml
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY actor-backup.sh /usr/local/bin/actor-backup.sh
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/actor-backup.sh

EXPOSE 3000
ENV PDS_PORT=3000
ENV NODE_ENV=production
# potential perf issues w/ io_uring on this version of node
ENV UV_USE_IO_URING=0

# Litestream wraps the PDS process — it replicates WAL changes continuously
# and forwards signals to the child process for graceful shutdown.
# If LITESTREAM_ACCESS_KEY_ID is not set, fall back to running PDS directly.
CMD ["entrypoint.sh"]

LABEL org.opencontainers.image.source=https://github.com/grishaLR/pds
LABEL org.opencontainers.image.description="protoimsg AT Protocol PDS"
LABEL org.opencontainers.image.licenses=MIT
