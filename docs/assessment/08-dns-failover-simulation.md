# 08 — DNS Failover Simulation (Option C) — LOCAL, not Route 53

[`scripts/dns-failover-sim.sh`](../../scripts/dns-failover-sim.sh): internal Docker network, test-only name `app.stockwatch.dr.test`; simulated `sydney`/`melbourne` endpoints; **CoreDNS** (`hosts` plugin, reload 1 s, TTL 5 s); a health-check controller (1 s interval; 3 failures → failover, 3 successes → failback) playing Route 53's role; a TTL-honouring client. Timings use CLOCK_MONOTONIC shared by all containers. Results: [09](09-rto-rpo-measurements.md).

## Why the existing Route 53 zone cannot provide public failover (Production verified facts)

`stockwatch-hz` is a **private** hosted zone associated only with the Sydney VPC, containing only NS/SOA; there are no health checks and no registered domain (Route 53 Domains is unavailable on this free-plan account). Private zones resolve only inside associated VPCs, so end users never query it; a Sydney outage also removes its only consumer. Public global failover needs a public hosted zone and a domain (not approved under the zero-cost constraint). Details: [`docs/dns-route53-analysis.md`](../dns-route53-analysis.md).

Mapping to Route 53: detection = interval × threshold (Route 53 standard: 30 s × 3 ≈ 90 s), client switch ≈ detection + TTL (60 s) → ≈ 90–150 s, versus ≈ 10 s with the simulation's parameters.
