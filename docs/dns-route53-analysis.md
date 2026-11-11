# Route 53 / DNS Analysis — `stockwatch-hz` (Phase 3)

**Status:** COMPLETE — DNS-level facts verified from inside the primary VPC (2026-11-10) and API-level facts verified with the read-only role (2026-11-11, `docs/aws/discovery-2026-11-11.md`). No hosted zone, record or health check has been created, changed or deleted.

## 1. Verified facts (2026-11-10, via the VPC resolver 169.254.169.253 from the primary host)

| Query | Result | Meaning |
|---|---|---|
| `stockwatch-hz.` SOA | NOERROR — `ns-1536.awsdns-00.co.uk. awsdns-hostmaster.amazon.com.` serial 1, negative TTL 86400 | a Route 53 zone literally named `stockwatch-hz` is resolvable **from the primary VPC** → it is associated with `vpc-02371e067f7e28e42` (or resolved via a rule) |
| `stockwatch-hz.` NS | `ns-0.awsdns-00.com`, `ns-1024.awsdns-00.org`, `ns-1536.awsdns-00.co.uk`, `ns-512.awsdns-00.net` | the standard placeholder name-server set Route 53 assigns to **private** hosted zones (consistent with "currently private") |
| A for `app`, `api`, `www`, `db`, `primary`, `secondary`, `stockwatch`, `redis`, `backend`, `frontend`, `dr` (`.stockwatch-hz`) | NXDOMAIN | none of the likely application names exist; the zone may contain only SOA/NS (to confirm with `ListResourceRecordSets`) |
| `stockwatch-hz.internal` / `.local`, `stockwatch.internal` | NXDOMAIN | no similarly named zones visible to this VPC |

`stockwatch-hz` is a single-label name (no public TLD); it could never be delegated publicly.

## 2. Pending API inspection (read-only role, policy v1.0)

```bash
aws route53 list-hosted-zones-by-name --dns-name stockwatch-hz        # ListHostedZonesByName was removed in v1.0; use list-hosted-zones
aws route53 list-hosted-zones --query "HostedZones[?Name=='stockwatch-hz.']"
aws route53 get-hosted-zone --id <ZONE_ID>                            # Config.PrivateZone + VPCs (all associated VPCs/regions)
aws route53 list-resource-record-sets --hosted-zone-id <ZONE_ID>      # records, routing policies (Failover/SetIdentifier), HealthCheckId
aws route53 list-health-checks                                        # any existing checks (and how many: first 50 AWS-endpoint checks are free)
```

## 2a. API-verified facts (2026-11-11)

| Fact | Value |
|---|---|
| Zone | `stockwatch-hz.` — `Z09769103NHQ10AO183K7` |
| Type | **private** (`Config.PrivateZone = true`), no delegation set |
| VPC associations | `vpc-02371e067f7e28e42` (ap-southeast-2) only |
| Records | 2: NS (TTL 172800) and SOA (TTL 900) — no application records |
| Routing policies | none (no failover / weighted / latency records) |
| Health checks (account) | none |
| Registered domains | none; Route 53 Domains API unavailable on this free-plan account |
| Dependencies | nothing resolves application names from this zone; changing it would not affect production |

## 3. Cost facts (AWS Price List, Route 53, retrieved 2026-11-10)

| Item | Price | Relevance |
|---|---|---|
| Hosted zone | $0.50/month (first 25) | `stockwatch-hz` already exists → **already billed**; records add no zone cost |
| Basic health check, AWS endpoint | **"First 50 Health Checks of AWS endpoints are free of charge"**, then $0.50/month | a basic HTTP check against the primary EC2 public IP is free (if the account has < 50) |
| Health-check optional features (HTTPS, string match, 10 s interval, latency) | $1.00/month each (AWS endpoints) | avoid for zero cost |
| Non-AWS endpoint health check | $0.75/month | not applicable |
| Standard queries | $0.40 per million | a demonstration issues a few thousand queries (< $0.01). Whether private-zone queries from the VPC resolver are billed at this rate is **not explicit in the price list** → treat as "≤ fractions of a cent", not guaranteed zero |

## 4. Why private DNS switching is NOT equivalent to public global DNS failover

| Aspect | Public global failover (target design) | Private zone `stockwatch-hz` |
|---|---|---|
| Who resolves it | any client on the internet via recursive resolvers | only resources inside **associated VPCs** using the VPC resolver |
| Users of StockWatch | browse to a public name → follow failover | do not use this zone at all; a switch here changes nothing for real users |
| Survives a Sydney region loss | Route 53 data plane is global; public answers keep flowing | the zone is global, but its only consumer (the Sydney VPC) is the failed region; Melbourne would need its own VPC association |
| Health checking | health checkers probe the public endpoint from multiple regions | checkers cannot reach private IPs; failover records must use public-endpoint or CloudWatch-alarm-based checks |
| Domain requirement | registered, delegated public domain | none (single-label name; cannot be delegated) |
| Caching | recursive resolvers honour TTL (60 s), some clients cache longer | VPC resolver honours TTL; no external caches |

Conclusion: anything demonstrated in `stockwatch-hz` proves **Route 53 failover-routing mechanics and health-check-driven answer changes**, not end-user global failover. Real global failover needs a public hosted zone and a registered domain (≈ $0.50/month zone + domain registration — not approved under the zero-cost constraint).

## 5. Recommendation — strongest demonstration without additional cost

**Tier 0 (done, zero cost, no AWS change):** local CoreDNS failover simulation (`scripts/dns-failover-sim.sh`, results in `docs/dr-assessment-evidence.md`) plus the DNS step of `dr-failover.sh` / `dr-failback.sh`. Proves health-check-driven record switching and TTL behaviour locally, not Route 53.

**Tier 1 (recommended; ~$0, needs approval and write permissions):** real Route 53 failover routing in the existing private zone, without touching production traffic:

1. Basic HTTP health check `stockwatch-primary-hc` → primary public IP, port 80, path `/api/health`, interval 30 s, threshold 3 (free: AWS endpoint, no optional features).
2. In `stockwatch-hz`: `app.stockwatch-hz` A **Failover PRIMARY** → `172.31.1.61` (primary private IP) with `stockwatch-primary-hc`, TTL 60; **Failover SECONDARY** → a documented secondary target (a stand-in private address for the Melbourne host, which does not exist).
3. Demonstrate failover by **inverting the health check** (`update-health-check --inverted`): Route 53 treats PRIMARY as unhealthy while production keeps serving normally (nobody consumes `app.stockwatch-hz`). From the primary host, poll the VPC resolver every second and record: T0 (inversion) → health-check status flips (`get-health-check-status`) → resolver answer changes to SECONDARY. Revert (`--no-inverted`) and measure failback the same way.
4. Clean up the records and the health check afterwards (approval), or keep them for the walkthrough.

This yields **real, measured Route 53 detection + answer-switch timings** at no incremental charge (within the free 50 health checks; query charges, if any, are fractions of a cent).

Required (not in policy v1.0, separate approval): `route53:CreateHealthCheck`, `route53:UpdateHealthCheck`, `route53:DeleteHealthCheck` (on the one check), `route53:ChangeResourceRecordSets` and `route53:GetChange` scoped to the `stockwatch-hz` zone ARN.

**Tier 2 (not zero cost; not proposed):** public hosted zone + registered domain + Melbourne EIP for true end-user global failover.
