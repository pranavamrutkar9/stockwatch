# StockWatch Walkthrough Script (Under 180 Seconds)

Record the actual implementation on screen. Do not use slides as a substitute.

| Time | What to show | Talking point |
|---|---|---|
| 0:00–0:30 | Architecture diagram and cloud VM | Explain the five services and private service communication. |
| 0:30–1:00 | Three Dockerfiles and Compose | Explain multi-stage images, health checks, network, and persistent volume. |
| 1:00–1:40 | Successful GitHub Actions run and GHCR | Show SHA-tagged images and explain why failed checks block deployment. |
| 1:40–2:20 | Public app, inventory, stock check result | Show the API → Redis/BullMQ → worker → PostgreSQL workflow. |
| 2:20–2:50 | Secrets configuration (names only), logs, rollback | Explain persistence, crash handling, and how to restore the previous image SHA. |

Target duration: about 170 seconds maximum, leaving a small buffer. The submitted recording must be strictly less than 180 seconds.

## Final recording checklist

- [ ] Actual screen recording, not a slide deck.
- [ ] Public URL is visible and working.
- [ ] No secret values are visible.
- [ ] Video is under 180 seconds.
- [ ] Demonstrated behaviour matches the deployed implementation.
