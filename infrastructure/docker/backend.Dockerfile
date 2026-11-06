# ==========================================
# Stage 1: Builder
# ==========================================
FROM node:22-alpine AS builder
RUN apk add --no-cache libc6-compat openssl
WORKDIR /app
RUN corepack enable && corepack prepare pnpm@11.5.0 --activate

COPY package.json pnpm-lock.yaml pnpm-workspace.yaml .npmrc ./
COPY packages/database ./packages/database
COPY apps/backend ./apps/backend

RUN pnpm install
RUN pnpm --filter @stockwatch/database build
RUN pnpm --filter @stockwatch/backend build

# ==========================================
# Stage 2: Runner
# ==========================================
FROM node:22-alpine AS runner
RUN apk add --no-cache openssl wget
WORKDIR /app

ENV NODE_ENV=production
ENV PORT=4000

USER node

COPY --from=builder --chown=node:node /app/node_modules ./node_modules
COPY --from=builder --chown=node:node /app/packages/database ./packages/database
COPY --from=builder --chown=node:node /app/apps/backend ./apps/backend
COPY --from=builder --chown=node:node /app/package.json ./package.json

EXPOSE 4000

HEALTHCHECK --interval=10s --timeout=5s --start-period=10s --retries=5 \
  CMD wget --no-verbose --tries=1 --spider http://127.0.0.1:4000/api/health || exit 1

CMD ["node", "apps/backend/dist/main.js"]
