# IAM Read-only Discovery Policy — Permission-by-Permission Review

**Policy:** `docs/aws/iam-readonly-discovery-policy.json` · **Status:** for review; not created or attached.
Generated from the policy file so that every action is covered (the generator fails if an action lacks a rationale).

Columns: **Purpose** (why the DR work needs it) · **Exposes** (what it can reveal) · **Risk** (None = public catalog/status; Low = account metadata, no secrets or data) · **Keep?** (Essential / Recommended / Optional — Optional rows can be removed to tighten further).

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
| `rds:DescribeOptionGroups` | Option group compatibility for restore | Option metadata | Low | Optional (PostgreSQL rarely uses options) |
| `rds:DescribeDBEngineVersions` | Confirm PostgreSQL 16.15 is available in Melbourne | Public catalog | None | Essential |
| `rds:DescribeOrderableDBInstanceOptions` | Confirm db.t4g.micro + PG16 + storage type orderable in Melbourne | Public catalog | None | Essential |
| `rds:DescribeSourceRegions` | Confirm Sydney→Melbourne backup replication/replica support via API | Public catalog | None | Essential |
| `rds:DescribeCertificates` | CA identifier/expiry for TLS validation in both regions | Public CA metadata | None | Recommended |
| `rds:DescribeEvents` | When the master password was changed (today's incident timeline), backups, failovers | Event messages | Low | Essential |
| `rds:DescribeEventSubscriptions` | Existing alerting on RDS events | Subscription config | Low | Optional |
| `rds:DescribePendingMaintenanceActions` | Maintenance that could interfere with DR tests | Maintenance metadata | Low | Recommended |
| `rds:DescribeAccountAttributes` | RDS quotas (instances, storage, cross-region backups) | Quota values | None | Recommended |
| `rds:DescribeDBLogFiles` | Log file names/sizes only (download explicitly denied) | File names | Low | Optional |
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
| `ec2:DescribeKeyPairs` | Which key pair is used (decide SSM vs SSH for DR host) | Key names/fingerprints; no private keys | Low | Optional |
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
| `ec2:DescribeVpcEndpoints` | Existing endpoints (SSM/S3) affecting DR design | Endpoint metadata | Low | Optional |
| `ec2:DescribeAvailabilityZones` | AZ names/IDs in both regions | Public | None | Essential |
| `ec2:DescribeRegions` | **Opt-in status of ap-southeast-4** (use --all-regions) | Region list | None | Essential |
| `ec2:DescribeTags` | Tag conventions | Tags | Low | Optional |
| `ec2:DescribeManagedPrefixLists` | Route 53 health-checker prefix list for SG rules | Public prefix lists | None | Recommended |
| `ec2:GetManagedPrefixListEntries` | CIDRs of the health-checker prefix list | Public CIDRs | None | Recommended |

## `KmsMetadataForEncryptedBackupsAndSecrets` — Allow (regions ap-southeast-2, ap-southeast-4, ap-southeast-1)

| Action | Purpose | Exposes | Risk | Keep? |
|---|---|---|---|---|
| `kms:ListKeys` | Find KMS keys (RDS/Secrets encryption) | Key IDs | Low | Essential if RDS is encrypted |
| `kms:ListAliases` | Identify aws/rds vs customer keys | Alias names | Low | Essential if RDS is encrypted |
| `kms:DescribeKey` | Key type/region/multi-region status → whether a Melbourne key is needed for encrypted replica/backups | Key metadata; no key material | Low | Essential if RDS is encrypted |
| `kms:GetKeyRotationStatus` | Key rotation posture | Boolean | None | Optional |

## `MonitoringReadOnly` — Allow (global / not region-conditioned)

| Action | Purpose | Exposes | Risk | Keep? |
|---|---|---|---|---|
| `cloudwatch:DescribeAlarms` | Existing alarms | Alarm config | Low | Recommended |
| `cloudwatch:ListMetrics` | Available RDS/EC2 metrics (e.g. ReplicaLag) | Metric names | None | Recommended |
| `cloudwatch:GetMetricData` | Baseline CPU/connections/FreeStorage; ReplicaLag for RPO evidence | Metric values | Low | Essential (RPO measurement) |
| `cloudwatch:GetMetricStatistics` | Same, legacy API used by some CLI paths | Metric values | Low | Optional (duplicate of GetMetricData) |
| `logs:DescribeLogGroups` | Whether RDS logs are exported | Log group names only | None | Optional |
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

## `GlobalDnsAndPricingReadOnly` — Allow (global / not region-conditioned)

| Action | Purpose | Exposes | Risk | Keep? |
|---|---|---|---|---|
| `route53:ListHostedZones` | Does a hosted zone already exist? | Zone names | Low | Essential |
| `route53:ListHostedZonesByName` | Same, by name | Zone names | Low | Optional (duplicate) |
| `route53:GetHostedZone` | Name servers/delegation | NS records | Low | Essential |
| `route53:ListResourceRecordSets` | Existing records (avoid conflicts) | DNS records | Low | Essential |
| `route53:ListHealthChecks` | Existing health checks | Config | Low | Essential |
| `route53:GetHealthCheck` | Health check config | Config | Low | Essential |
| `route53:GetHealthCheckStatus` | Per-checker status during failover tests (detection-time evidence) | Status | None | Essential |
| `route53:GetHealthCheckLastFailureReason` | Failure reasons during tests | Status | None | Recommended |
| `route53domains:ListDomains` | Is a domain registered in this account? | Domain names | Low | Essential |
| `pricing:DescribeServices` | Pricing API discovery | Public | None | Optional (public Price List files used instead) |
| `pricing:GetAttributeValues` | Pricing API discovery | Public | None | Optional |
| `pricing:GetProducts` | Verified prices | Public | None | Optional (public offer files already used) |

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

- 78 allowed actions, all `Describe*`/`List*`/`Get*`; 13 explicitly denied actions. No wildcards, no write actions.
- **Resource scoping:** these read actions largely do not support resource-level ARNs (AWS requires `*`), so scope is enforced by the `aws:RequestedRegion` condition and the explicit Deny.
- **Residual exposure:** account-wide metadata (resource names, network layout, DNS records, bucket names, secret *names*). No secret values, object contents, user-data or database data.
- **Credential exposure on the host:** any host process can use the role. Recommend IMDSv2 hop limit 1 so containers cannot obtain credentials (separate approval).
- **Tightening option:** removing the 13 Optional actions (`rds:DescribeOptionGroups`, `rds:DescribeEventSubscriptions`, `rds:DescribeDBLogFiles`, `ec2:DescribeKeyPairs`, `ec2:DescribeVpcEndpoints`, `ec2:DescribeTags`, `kms:GetKeyRotationStatus`, `cloudwatch:GetMetricStatistics`, `logs:DescribeLogGroups`, `route53:ListHostedZonesByName`, `pricing:DescribeServices`, `pricing:GetAttributeValues`, `pricing:GetProducts`) leaves full DR-discovery capability.
- **Lifetime:** detach the role after discovery, or keep it only for the assessment window. Phase 4 write permissions are a separate policy and approval.

## Validation performed

- JSON parses; every Allow action matches `Describe*`/`List*`/`Get*`; policy size 4,862 characters (managed-policy limit 6,144).
- Not yet performed (requires AWS access): IAM Access Analyzer `ValidatePolicy`, and a post-attach negative test (`secretsmanager get-secret-value` must return AccessDenied).
