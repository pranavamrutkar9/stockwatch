# AWS Read-only Discovery — 2026-11-11

Identity: `assumed-role/stockwatch-dr-readonly-discovery/i-07590867e7e49c18b` (account ID withheld). All calls read-only; no AWS resource was created or modified.

## Role correction (before discovery)

The instance first carried `AWSEC2RoleforDefaultAWSServiceAccess` (AWS default "broad service access" role: 19 managed policies incl. S3/DynamoDB/ElastiCache/SNS/SQS FullAccess, RDS Data FullAccess). Discovery was stopped and reported; the user replaced it with the approved v1.0 role. Verified afterwards: `sts get-caller-identity` → `stockwatch-dr-readonly-discovery`.

## Permission tests (policy v1.0)

| Test | Result |
|---|---|
| EC2 / RDS describe in ap-southeast-2 | allowed |
| IAM `GetRole`, `ListAttachedRolePolicies` | AccessDenied (no IAM actions in v1.0) |
| `secretsmanager:GetSecretValue`, `BatchGetSecretValue` | **explicit deny** |
| `ssm:GetParameter` (with decryption) | **explicit deny** |
| EC2 user-data (`DescribeInstanceAttribute userData`) | **explicit deny** |
| EC2 console output | **explicit deny** |
| `kms:Decrypt` | **inconclusive at API level**: KMS validates ciphertext structure before authorization and the role cannot produce valid ciphertext (`kms:Encrypt` → AccessDenied). The explicit deny is present in the policy. |
| Writes: `ec2:CreateTags` (dry-run), `ec2:RunInstances` (dry-run, real public AMI), `rds:CreateDBSnapshot`, `rds:ModifyDBInstance`, `route53:ChangeResourceRecordSets`, `s3:CreateBucket`, `iam:CreateUser` | all denied (UnauthorizedOperation / AccessDenied); targets were non-existent or `--dry-run`, so nothing could change even if allowed |
| Other regions: RDS us-east-1, EC2 us-west-2, Secrets Manager eu-west-1 | denied |
| Containers reaching IMDS | **possible** (IMDSv2 hop limit 2) → recommendation: hop limit 1 |

## Primary infrastructure (ap-southeast-2)

| Resource | Facts |
|---|---|
| EC2 `i-07590867e7e49c18b` | c7i-flex.large, ap-southeast-2a, default VPC subnet, auto-assigned public IPv4 (**no Elastic IP**), IMDSv2 required, hop limit 2, root gp3 25 GiB **unencrypted** |
| VPC `vpc-02371e067f7e28e42` | default VPC 172.31.0.0/16; public subnets in 2a/2b/2c, private DB subnets 172.31.48.0/20 (2a), 172.31.64.0/20 (2b) |
| App SG `launch-wizard-1` | in: 80 from 0.0.0.0/0, 22 from one operator /32; out: all |
| DB SG `stockwatch-rds-sg` | in: 5432 **only from the app SG**; out: all |
| RDS `stockwatch-primary-db` | PostgreSQL 16.15, db.t4g.micro, Single-AZ (2a), 20 GiB gp2, **encrypted with AWS-managed `alias/aws/rds`** (not multi-region), not public, deletion protection on, CA `rds-ca-rsa2048-g1`, parameter group `default.postgres16`, auto minor upgrade off, IAM DB auth off |
| Backups | retention **1 day**, window 19:14–19:44 UTC; PITR window 2026-11-10T07:48Z → latest restorable (≈ 5 min behind); 2 automated snapshots; no manual snapshots |
| Master credentials | **not** Secrets Manager–managed (`MasterUserSecret` null); Secrets Manager holds no secrets |
| RDS events | `2026-11-10T17:04:17Z Reset master credentials` — **confirms the root cause of the 2026-11-10 outage** (manual reset under running containers; .env updated 17:12) |

## Route 53

One hosted zone `stockwatch-hz.` (`Z09769103NHQ10AO183K7`): **private**, associated only with `vpc-02371e067f7e28e42` (ap-southeast-2); records: NS + SOA only; no failover/weighted records; **no health checks** in the account. `route53domains:ListDomains` → "Free Tier accounts are not supported for this service" (account is on the AWS free plan).

## Melbourne (ap-southeast-4)

`ec2:DescribeRegions --all-regions` → **`not-opted-in`**. All Melbourne API calls fail (invalid token). PostgreSQL 16.15 availability, replica support and instance offerings therefore **cannot be verified via API** until the Region is enabled (account-level change, free, requires approval). Public sources (Price List, RDS documentation) previously confirmed support (`docs/disaster-recovery-design.md` §4a). Because the primary is encrypted with `aws/rds`, a Melbourne replica must use a KMS key in ap-southeast-4 (e.g. that Region's `aws/rds`).
