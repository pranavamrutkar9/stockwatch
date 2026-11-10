# ==========================================
# Stage 1: Builder
# ==========================================
FROM node:22-alpine AS builder
RUN apk add --no-cache libc6-compat openssl
WORKDIR /app
RUN corepack enable && corepack prepare pnpm@11.5.0 --activate

COPY package.json pnpm-lock.yaml pnpm-workspace.yaml .npmrc ./
COPY packages/database ./packages/database
COPY apps/worker ./apps/worker

RUN pnpm install
RUN pnpm --filter @stockwatch/database build
RUN pnpm --filter @stockwatch/worker build

# ==========================================
# Stage 2: Runner
# ==========================================
FROM node:22-alpine AS runner
RUN apk add --no-cache openssl
WORKDIR /app

ENV NODE_ENV=production

HEALTHCHECK --interval=15s --timeout=5s --start-period=45s --retries=3 \
  CMD ["node", "-e", "process.exit(require('node:fs').existsSync('/tmp/stockwatch-worker-ready') ? 0 : 1)"]

USER node

COPY --from=builder --chown=node:node /app/node_modules ./node_modules
COPY --from=builder --chown=node:node /app/packages/database ./packages/database
COPY --from=builder --chown=node:node /app/apps/worker ./apps/worker
COPY --from=builder --chown=node:node /app/package.json ./package.json

CMD ["node", "apps/worker/dist/index.js"]
