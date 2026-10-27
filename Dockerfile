# The quest image must be built for linux/amd64: bin/001-bin/006 are amd64 ELF
# binaries only, so an arm64 image would start node but fail every route.
#   docker build --platform linux/amd64 -t quest .
#
# Base: node:22-slim (22-bookworm-slim), pinned to its linux/amd64 manifest digest
# as listed by `docker buildx imagetools inspect node:22-slim` on 2026-10-27.
FROM node:22-slim@sha256:ea11b74b986d520137cdef9a5346e447a00f275ecc4abc0055b7151226231e09

ENV NODE_ENV=production

# The slim image has no CA bundle, and bin/001 (Go) fetches an HTTPS page for
# the index route; without system roots it panics with "x509: certificate
# signed by unknown authority".
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# src/000.js runs execFile('bin/00N'), resolved against the working directory.
WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force

# Root-owned and not writable by the runtime user; bin/ keeps its executable bit.
COPY src/ ./src/
COPY --chmod=0755 bin/ ./bin/

USER node

EXPOSE 3000

CMD ["node", "src/000.js"]
