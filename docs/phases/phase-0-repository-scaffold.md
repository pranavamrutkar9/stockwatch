# Phase 0 — Repository Scaffold

## Read first
`AGENTS.md`, then context documents 00, 04, 05, and 14.

## Goal
Create only the agreed StockWatch monorepo skeleton and workspace configuration.

## Tasks
1. Inspect the current repository before changing anything.
2. Create the directory structure exactly as specified in `04-repository-structure.md`.
3. Add root `package.json` with pnpm workspace scripts only when their commands exist; do not add broken scripts.
4. Add `pnpm-workspace.yaml` covering `apps/*` and `packages/*`.
5. Add minimal private package manifests for the workspace packages that are being initialized.
6. Add `.gitignore` for node_modules, build outputs, `.env`, logs, and local runtime data.
7. Add `.env.example` with placeholder variable names only; no real credentials.
8. Add placeholder `README.md` only if needed. Do not write the full README yet.

## Do not
- Do not implement application features.
- Do not install unrelated dependencies.
- Do not create Dockerfiles or CI workflows in this phase.
- Do not change the agreed folder structure.

## Acceptance
- Workspace structure matches the repository document.
- `pnpm install` succeeds and creates a lockfile.
- No secrets are present.
- No app logic is implemented.

## Report
List files created, commands run, actual output, and any blockers.
