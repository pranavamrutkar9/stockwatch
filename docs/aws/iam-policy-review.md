# IAM Read-only Discovery Policy — Final Permission-by-Permission Review (v1.0)

**Policy:** `docs/aws/iam-readonly-discovery-policy.json` · **Status:** FINAL DRAFT for approval — not created or attached. Version 1.0 (2026-11-10): the 13 actions previously marked Optional were removed.
Generated from the policy file so that every action is covered (the generator fails if an action lacks a rationale).

Columns: **Purpose** (why the DR work needs it) · **Exposes** (what it can reveal) · **Risk** (None = public catalog/status; Low = account metadata, no secrets or data) · **Keep?** (Essential / Recommended).

## `RdsReadOnlyDiscovery` — Allow (regions ap-southeast-2, ap-southeast-4, ap-southeast-1)

| Action | Purpose | Exposes | Risk | Keep? |
|---|---|---|---|---|
| `rds:DescribeDBInstances` | Primary DB config: retention, LatestRestorableTime, encryption/KMS key, Multi-AZ, SGs, subnet group, CA, **MasterUserSecret** (managed-rotation check) | Instance metadata incl. endpoint and master username; no password | Low | Essential |
| `rds:DescribeDBInstanceAutomatedBackups` | Automated backup/PITR window, replicated backups in Melbourne | Backup metadata | Low | Essential |
| `rds:DescribeDBSnapshots` | Existing manual/automated snapshots for restore planning | Snapshot metadata | Low | Essential |
| `rds:DescribeDBSnapshotAttributes` | Whether any snapshot is shared/public (security check) | Snapshot sharing attributes | Low | Recommended |
| `rds:DescribeDBSubnetGroups` | Private subnet layout to mirror in Melbourne | Subnet IDs | Low | Essential |
| `rds:DescribeDBParameterGroups` | Parameter group to replicate in DR | Group names | Low | Essential |
| `rds:DescribeDBParameters` | Non-default parameters (e.g. rds.force_ssl) to replicate | Parameter values (no secrets) | Low | Essential |
| `rds:DescribeDBEngineVersions` | Confirm PostgreSQL 16.15 is available in Melbourne | Public catalog | None | Essential |
| `rds:DescribeOrderableDBInstanceOptions` | Confirm db.t4g.micro + PG16 + storage type orderable in Melbourne | Public catalog | None | Essential |
| `rds:DescribeSourceRegions` | Confirm Sydney→Melbourne backup replication/replica support via API | Public catalog | None | Essential |
| `rds:DescribeCertificates` | CA identifier/expiry for TLS validation in both regions | Public CA metadata | None | Recommended |
| `rds:DescribeEvents` | When the master password was changed (today's incident timeline), backups, failovers | Event messages | Low | Essential |
| `rds:DescribePendingMaintenanceActions` | Maintenance that could interfere with DR tests | Maintenance metadata | Low | Recommended |
| `rds:DescribeAccountAttributes` | RDS quotas (instances, storage, cross-region backups) | Quota values | None | Recommended |
| `rds:ListTagsForResource` | Tags for ownership/cost allocation | Tags | Low | Recommended |

## `SecretsManagerMetadataOnly` — Allow (regions ap-southeast-2, ap-southeast-4, ap-southeast-1)

| Action | Purpose | Exposes | Risk | Keep? |
|---|---|---|---|---|
| `secretsmanager:ListSecrets` | Find the RDS-managed secret (rds!db-*) and any app secrets | Secret names/metadata, rotation config; **no values** | Low | Essential (cannot be resource-scoped) |
| `secretsmanager:DescribeSecret` | RotationEnabled, RotationRules, LastRotatedDate, NextRotationDate — root-cause recurrence check | Rotation metadata; **no value** | Low | Essential |
| `secretsmanager:ListSecretVersionIds` | Version stages/timestamps — correlate rotation with the 17:12 UTC change | Version IDs/dates; no value | Low | Recommended |

## `Ec2AndNetworkingReadOnly` — Allow (regions ap-southeast-2, ap-southeast-4, ap-southeast-1)

| Action | Purpose | Exposes | Risk | Keep? |
|---|---|---|---|---|
| `ec2:DescribeInstances` | Primary instance config, IMDS options (hop limit), public IP/EIP, AZ, AMI | Instance metadata (not user-data) | Low | Essential |
| `ec2:DescribeInstanceStatus` | Health/scheduled events on primary | Status | None | Recommended |
| `ec2:DescribeInstanceTypes` | Architecture/size of x86 candidates (images are amd64-only) | Public catalog | None | Recommended |
| `ec2:DescribeInstanceTypeOfferings` | Confirm t3.small/c7i-flex availability per Melbourne AZ | Public catalog | None | Essential |
| `ec2:DescribeIamInstanceProfileAssociations` | Verify which role is attached | Role ARN | Low | Recommended |
| `ec2:DescribeVolumes` | Root volume size/type/encryption for DR sizing and snapshot policy | Volume metadata | Low | Essential |
| `ec2:DescribeSnapshots` | Existing EBS snapshots (filter by owner self) | Snapshot metadata | Low | Recommended |
| `ec2:DescribeImages` | AMI lineage of primary; candidate Ubuntu AMIs in Melbourne | AMI metadata | None | Essential |
| `ec2:DescribeAddresses` | Whether primary has an Elastic IP (DNS failover prerequisite) | EIP allocation | Low | Essential |
| `ec2:DescribeVpcs` | VPC CIDR to choose a non-overlapping DR CIDR | VPC metadata | Low | Essential |
| `ec2:DescribeSubnets` | Subnet/AZ layout | Subnet metadata | Low | Essential |
| `ec2:DescribeRouteTables` | Public/private routing model | Routes | Low | Essential |
| `ec2:DescribeInternetGateways` | Internet egress model | IGW IDs | Low | Essential |
| `ec2:DescribeNatGateways` | Whether NAT exists (cost driver) | NAT metadata | Low | Recommended |
| `ec2:DescribeNetworkAcls` | NACL rules that could block health checks/replication | Rules | Low | Recommended |
| `ec2:DescribeNetworkInterfaces` | ENIs of RDS/EC2 (private IPs, SG attachment) | ENI metadata | Low | Recommended |
| `ec2:DescribeSecurityGroups` | Verify DB SG only allows app SG; app SG exposure of 22/80 | SG rules | Low | Essential |
| `ec2:DescribeSecurityGroupRules` | Rule-level detail incl. descriptions | SG rules | Low | Essential |
| `ec2:DescribeAvailabilityZones` | AZ names/IDs in both regions | Public | None | Essential |
| `ec2:DescribeRegions` | **Opt-in status of ap-southeast-4** (use --all-regions) | Region list | None | Essential |
| `ec2:DescribeManagedPrefixLists` | Route 53 health-checker prefix list for SG rules | Public prefix lists | None | Recommended |
| `ec2:GetManagedPrefixListEntries` | CIDRs of the health-checker prefix list | Public CIDRs | None | Recommended |

## `KmsMetadataForEncryptedBackupsAndSecrets` — Allow (regions ap-southeast-2, ap-southeast-4, ap-southeast-1)

| Action | Purpose | Exposes | Risk | Keep? |
|---|---|---|---|---|
| `kms:ListKeys` | Find KMS keys (RDS/Secrets encryption) | Key IDs | Low | Essential if RDS is encrypted |
| `kms:ListAliases` | Identify aws/rds vs customer keys | Alias names | Low | Essential if RDS is encrypted |
| `kms:DescribeKey` | Key type/region/multi-region status → whether a Melbourne key is needed for encrypted replica/backups | Key metadata; no key material | Low | Essential if RDS is encrypted |

## `MonitoringReadOnly` — Allow (global / not region-conditioned)

| Action | Purpose | Exposes | Risk | Keep? |
|---|---|---|---|---|
| `cloudwatch:DescribeAlarms` | Existing alarms | Alarm config | Low | Recommended |
| `cloudwatch:ListMetrics` | Available RDS/EC2 metrics (e.g. ReplicaLag) | Metric names | None | Recommended |
| `cloudwatch:GetMetricData` | Baseline CPU/connections/FreeStorage; ReplicaLag for RPO evidence | Metric values | Low | Essential (RPO measurement) |
| `backup:ListBackupPlans` | Whether AWS Backup already protects resources | Plan metadata | Low | Recommended |
| `backup:ListBackupVaults` | Existing vaults (cross-region copy target) | Vault metadata | Low | Recommended |
| `backup:ListProtectedResources` | Which resources AWS Backup covers | Resource ARNs | Low | Recommended |
| `backup:ListRecoveryPointsByResource` | Recovery points for RDS/EBS | Recovery point metadata | Low | Recommended |
| `ssm:DescribeParameters` | Parameter **names** for secret distribution design (values denied) | Names/types | Low | Recommended |
| `ssm:DescribeInstanceInformation` | Whether SSM agent is registered (SSH-less operations) | Managed instance metadata | Low | Recommended |
| `s3:ListAllMyBuckets` | Find existing Terraform state / backup buckets | Bucket names (account-wide) | Low | Recommended |
| `s3:GetBucketLocation` | Bucket region | Region | None | Recommended |
| `s3:GetBucketVersioning` | State-bucket suitability | Boolean | None | Recommended |
| `s3:GetEncryptionConfiguration` | State-bucket encryption | Config | None | Recommended |
| `s3:GetBucketPublicAccessBlock` | State-bucket exposure | Config | None | Recommended |

## `GlobalDnsReadOnly` — Allow (global / not region-conditioned)

| Action | Purpose | Exposes | Risk | Keep? |
|---|---|---|---|---|
| `route53:ListHostedZones` | Does a hosted zone already exist? | Zone names | Low | Essential |
| `route53:GetHostedZone` | Name servers/delegation | NS records | Low | Essential |
| `route53:ListResourceRecordSets` | Existing records (avoid conflicts) | DNS records | Low | Essential |
| `route53:ListHealthChecks` | Existing health checks | Config | Low | Essential |
| `route53:GetHealthCheck` | Health check config | Config | Low | Essential |
| `route53:GetHealthCheckStatus` | Per-checker status during failover tests (detection-time evidence) | Status | None | Essential |
| `route53:GetHealthCheckLastFailureReason` | Failure reasons during tests | Status | None | Recommended |
| `route53domains:ListDomains` | Is a domain registered in this account? | Domain names | Low | Essential |

## `ExplicitlyDenySecretValuesAndDataReads` — Deny (global / not region-conditioned)

| Denied action | Protects |
|---|---|
| `secretsmanager:GetSecretValue` | secret values (incl. RDS master password) |
| `secretsmanager:BatchGetSecretValue` | secret values in bulk |
| `ssm:GetParameter` | SecureString values |
| `ssm:GetParameters` | SecureString values |
| `ssm:GetParametersByPath` | SecureString values |
| `kms:Decrypt` | decrypting any ciphertext |
| `s3:GetObject` | object contents (state files can contain secrets) |
| `rds:DownloadDBLogFilePortion` | DB logs (may contain SQL/data) |
| `rds-db:connect` | IAM DB authentication |
| `ec2:GetConsoleOutput` | boot console (can echo secrets) |
| `ec2:GetPasswordData` | Windows admin password |
| `ec2:DescribeInstanceAttribute` | user-data (can contain secrets) |
| `ec2:DescribeLaunchTemplateVersions` | launch-template user-data |

## Review summary

- 65 allowed actions (was 78), all `Describe*`/`List*`/`Get*`; 13 explicitly denied actions. No wildcards, no write actions.
- **Resource scoping:** these read actions largely do not support resource-level ARNs (AWS requires `*`), so scope is enforced by the `aws:RequestedRegion` condition and the explicit Deny.
- **Residual exposure:** account-wide metadata (resource names, network layout, DNS records, bucket names, secret *names*). No secret values, object contents, user-data or database data.
- **Credential exposure on the host:** any host process can use the role. Recommend IMDSv2 hop limit 1 so containers cannot obtain credentials (separate approval).
- **Removed in v1.0:** `cloudwatch:GetMetricStatistics`, `ec2:DescribeKeyPairs`, `ec2:DescribeTags`, `ec2:DescribeVpcEndpoints`, `kms:GetKeyRotationStatus`, `logs:DescribeLogGroups`, `pricing:DescribeServices`, `pricing:GetAttributeValues`, `pricing:GetProducts`, `rds:DescribeDBLogFiles`, `rds:DescribeEventSubscriptions`, `rds:DescribeOptionGroups`, `route53:ListHostedZonesByName`. Pricing now comes from the public AWS Price List files; none of the removed actions is needed for DR discovery.
- **Lifetime:** detach the role after discovery, or keep it only for the assessment window. Phase 4 write permissions are a separate policy and approval.

## Validation performed

- JSON parses; every Allow action (checked by regex) matches `Describe*`/`List*`/`Get*`; policy size 3,208 non-whitespace characters (managed-policy limit 6,144).
- Not yet performed (requires AWS access): IAM Access Analyzer `ValidatePolicy`, and a post-attach negative test (`secretsmanager get-secret-value` must return AccessDenied).

## Trust policy review (`docs/aws/ec2-trust-policy.json`)

| Element | Value | Assessment |
|---|---|---|
| Principal | `Service: ec2.amazonaws.com` | Only EC2 can assume the role, and only for instances it is attached to via an instance profile. |
| Action | `sts:AssumeRole` | Minimal; no `sts:TagSession`/`SetSourceIdentity`. |
| Conditions | none | `aws:SourceAccount`/`aws:SourceArn` are not populated for EC2 instance-profile role assumption, so a condition would not add protection. Exposure is controlled by *which instance the profile is attached to* (`iam:PassRole` is required to attach it, held only by your admin identity). |
| Human / cross-account principals | none | Nobody can assume the role from a console or another account. |

## Approval checklist

| # | Check | Status |
|---|---|---|
| 1 | Every Allow action is read-only (`Describe*`/`List*`/`Get*`) with no wildcards | Verified locally (regex) |
| 2 | Secret values, parameter values, object contents, user-data, console output and DB log contents are explicitly denied | Verified in policy |
| 3 | Region-scoped to ap-southeast-2 / ap-southeast-4 / ap-southeast-1 where the service is regional | Verified in policy |
| 4 | Policy size within managed-policy limit (6,144 non-whitespace characters) | Verified |
| 5 | IAM Access Analyzer `ValidatePolicy` returns no errors/security warnings | **Pending** — run when creating the policy (console shows findings automatically) |
| 6 | Trust policy allows only `ec2.amazonaws.com` | Verified |
| 7 | Attach only to `i-07590867e7e49c18b` | Your action |
| 8 | IMDSv2 hop limit 1 (containers cannot fetch credentials) | Recommended; your decision (separate change) |

## Attach → verify → detach procedure

1. Create policy `stockwatch-dr-readonly-discovery` from the JSON; review Access Analyzer findings.
2. Create role `stockwatch-dr-readonly-discovery` (trusted entity: AWS service → EC2), attach the policy.
3. Attach the role to `i-07590867e7e49c18b` (EC2 → Actions → Security → Modify IAM role). No restart.
4. Verification I will run (read-only), with expected outcomes:
   - `aws sts get-caller-identity` → assumed-role ARN for this role.
   - `aws rds describe-db-instances --region ap-southeast-2` → succeeds.
   - Negative: `aws secretsmanager get-secret-value --secret-id <rds secret arn>` → **AccessDenied** (explicit deny).
   - Negative: `aws ec2 describe-instance-attribute --attribute userData --instance-id i-07590867e7e49c18b` → **AccessDenied**.
   - Negative: `aws rds describe-db-instances --region us-east-1` → **AccessDenied** (region condition).
   - Negative (write): `aws rds modify-db-instance … --dry-run`-style calls are not available for RDS; instead `aws ec2 create-tags --dry-run --resources i-07590867e7e49c18b --tags Key=x,Value=y` → **UnauthorizedOperation** (proves no write access without changing anything).
5. Detach the role after discovery, or keep it for the assessment window only.
