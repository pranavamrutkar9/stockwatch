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
COPY apps/worker/package.json ./apps/worker/

# Install dependencies
RUN pnpm install --frozen-lockfile --filter=@stockwatch/database... --filter=@stockwatch/worker...

# ==========================================
# Stage 2: Builder
# ==========================================
FROM node:22-alpine AS builder
RUN apk add --no-cache openssl
WORKDIR /app
RUN corepack enable && corepack prepare pnpm@11.5.0 --activate

COPY --from=deps /app/node_modules ./node_modules
COPY --from=deps /app/packages/database/node_modules ./packages/database/node_modules
COPY --from=deps /app/apps/worker/node_modules ./apps/worker/node_modules
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml .npmrc ./
COPY packages/database ./packages/database
COPY apps/worker ./apps/worker

# Generate Prisma client and compile TypeScript
RUN pnpm --filter @stockwatch/database build
RUN pnpm --filter @stockwatch/worker build

# ==========================================
# Stage 3: Runner
# ==========================================
FROM node:22-alpine AS runner
RUN apk add --no-cache openssl
WORKDIR /app

ENV NODE_ENV=production

USER node

COPY --from=builder --chown=node:node /app/node_modules ./node_modules
COPY --from=builder --chown=node:node /app/packages/database ./packages/database
COPY --from=builder --chown=node:node /app/apps/worker/dist ./apps/worker/dist
COPY --from=builder --chown=node:node /app/apps/worker/package.json ./apps/worker/package.json
COPY --from=builder --chown=node:node /app/package.json ./package.json

CMD ["node", "apps/worker/dist/index.js"]
