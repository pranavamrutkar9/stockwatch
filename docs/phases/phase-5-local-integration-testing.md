# Phase 5 — Local Integration and Failure Testing

## Read first
`AGENTS.md`, context 08, 12, 13, and 15.

## Goal
Verify the full local Compose deployment before CI/CD or cloud work.

## Tasks
1. Run the full Compose stack from a clean state.
2. Test inventory CRUD through the UI/API.
3. Submit a stock check and verify worker processing.
4. Verify completed totals and alert snapshots.
5. Trigger the controlled failure path and verify FAILED status.
6. Restart containers and verify PostgreSQL persistence.
7. Stop Redis or worker temporarily and observe/log the failure behaviour; restore service and verify recovery.
8. Fix issues found; do not proceed with known critical failures.

## Acceptance
All critical application and container acceptance criteria pass locally. Record exact test results and known limitations.
