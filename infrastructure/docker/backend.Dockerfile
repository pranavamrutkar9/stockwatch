# ==========================================
# Stage 1: Base & Dependencies
# ==========================================
FROM node:22-alpine AS deps
RUN apk add --no-cache libc6-compat openssl
WORKDIR /app

RUN corepack enable && corepack prepare pnpm@11.5.0 --activate

# Copy monorepo configuration
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml .npmrc ./
COPY packages/database/package.json ./packages/database/
COPY packages/database/prisma ./packages/database/prisma
COPY apps/backend/package.json ./apps/backend/

# Install dependencies
RUN pnpm install --frozen-lockfile --filter=@stockwatch/database... --filter=@stockwatch/backend...

# ==========================================
# Stage 2: Builder
# ==========================================
FROM node:22-alpine AS builder
RUN apk add --no-cache openssl
WORKDIR /app
RUN corepack enable && corepack prepare pnpm@11.5.0 --activate

COPY --from=deps /app/node_modules ./node_modules
COPY --from=deps /app/packages/database/node_modules ./packages/database/node_modules
COPY --from=deps /app/apps/backend/node_modules ./apps/backend/node_modules
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml .npmrc ./
COPY packages/database ./packages/database
COPY apps/backend ./apps/backend

# Generate Prisma client and compile TypeScript
RUN pnpm --filter @stockwatch/database build
RUN pnpm --filter @stockwatch/backend build

# ==========================================
# Stage 3: Runner
# ==========================================
FROM node:22-alpine AS runner
RUN apk add --no-cache openssl wget
WORKDIR /app

ENV NODE_ENV=production
ENV PORT=4000

USER node

COPY --from=builder --chown=node:node /app/node_modules ./node_modules
COPY --from=builder --chown=node:node /app/packages/database ./packages/database
COPY --from=builder --chown=node:node /app/apps/backend/dist ./apps/backend/dist
COPY --from=builder --chown=node:node /app/apps/backend/package.json ./apps/backend/package.json
COPY --from=builder --chown=node:node /app/package.json ./package.json

EXPOSE 4000

HEALTHCHECK --interval=15s --timeout=5s --start-period=15s --retries=3 \
  CMD wget --no-verbose --tries=1 --spider http://127.0.0.1:4000/api/health || exit 1

CMD ["node", "apps/backend/dist/main.js"]
