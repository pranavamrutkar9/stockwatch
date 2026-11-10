# AWS Access Requirements — Read-only Discovery

**Status:** PREPARED. Nothing has been created, attached or configured.
**Verified current state (2026-11-10):** IMDSv2 `iam/info` on `i-07590867e7e49c18b` returns **404** (no instance profile attached). AWS CLI is not installed.

## Why access is needed now

1. **Recurrence risk of today's outage.** The RDS password changed under running containers. Need to confirm whether `stockwatch-primary-db` uses Secrets Manager–managed master credentials (`MasterUserSecret` in `DescribeDBInstances`) and its rotation schedule (`DescribeSecret` → `RotationEnabled`, `RotationRules`, `NextRotationDate`). Metadata only — secret *values* are explicitly denied.
2. **Ground truth for DR design:** backup retention, latest restorable time, storage encryption + KMS key (cross-region copies of encrypted backups need a destination-region key), engine minor version, parameter group, subnet group, security groups, public IP vs Elastic IP, root volume.
3. **DR region feasibility:** `rds:DescribeSourceRegions` (is cross-region automated-backup replication available Sydney → candidate region), `DescribeOrderableDBInstanceOptions` (db.t4g.micro / PG 16 availability), `DescribeInstanceTypeOfferings` (EC2 type availability).
4. **Cost estimates** from the Pricing API instead of guesses.
5. **Route 53:** whether a hosted zone / registered domain already exists.

## Recommended mechanism

An **EC2 instance role** (no long-lived keys on the host), as required by the assessment rules.

| Item | Value |
|---|---|
| Role name (suggested) | `stockwatch-dr-readonly-discovery` |
| Trust policy | `docs/aws/ec2-trust-policy.json` (`ec2.amazonaws.com`) |
| Permissions | `docs/aws/iam-readonly-discovery-policy.json` (customer-managed policy) |
| Attach to | instance profile on `i-07590867e7e49c18b` |
| Max session | default (credentials auto-rotated by IMDS) |

**Not recommended:** `AdministratorAccess`, `PowerUserAccess`, or the AWS-managed `ReadOnlyAccess` (it is far broader — it includes e.g. `s3:GetObject` on every bucket and `ec2:GetConsoleOutput`).

### Hardening recommendation (optional, your decision)

Containers on this host can reach IMDS. With IMDSv2 and a **hop limit of 1**, containers on the Docker bridge network cannot obtain the role credentials; only host processes can. Setting this is an EC2 metadata-option change on the production instance — not performed, listed for approval.

## Policy design

Region-scoped with `aws:RequestedRegion` to **ap-southeast-2** (primary) plus the two DR-region candidates **ap-southeast-4** (Melbourne) and **ap-southeast-1** (Singapore). Global services (Route 53, Pricing, S3 bucket listing, CloudWatch) are not region-conditioned because their requests resolve to fixed regions.

| Statement | Purpose | Notes |
|---|---|---|
| `RdsReadOnlyDiscovery` | instance config, automated backups, snapshots, source regions, orderable options, CA certificates, events, maintenance | `DescribeDBInstances` also returns `MasterUserSecret` ARN/status |
| `SecretsManagerMetadataOnly` | rotation enabled/schedule/last rotated for the RDS-managed secret | `ListSecrets` cannot be resource-scoped; `DescribeSecret` returns no secret value |
| `Ec2AndNetworkingReadOnly` | instance, EBS, AMIs, VPC, subnets, routes, SGs + rules, ENIs, EIPs, prefix lists, AZs, type offerings | deliberately excludes `DescribeInstanceAttribute` and `DescribeLaunchTemplateVersions` (expose user-data, which can contain secrets) |
| `KmsMetadataForEncryptedBackupsAndSecrets` | key IDs/aliases/rotation status | no `Decrypt` |
| `MonitoringReadOnly` | CloudWatch metrics/alarms, log group names, AWS Backup inventory, SSM parameter *names*, S3 bucket metadata (Terraform state bucket discovery) | no object reads |
| `GlobalDnsAndPricingReadOnly` | hosted zones, records, health checks, registered domains, price lists | |
| `ExplicitlyDenySecretValuesAndDataReads` | defence in depth | an explicit Deny overrides any Allow, including future broader policies on the same role |

Validation performed locally: both files parse as JSON; every `Allow` action is a `Describe*`/`List*`/`Get*` action with no wildcards; policy is 4,862 characters (managed-policy limit 6,144). IAM Access Analyzer policy validation should be run when the policy is created (requires AWS access).

## Minimum action required from you

Using your own AWS console/CLI session (not on this host):

1. Create customer-managed policy `stockwatch-dr-readonly-discovery` from `docs/aws/iam-readonly-discovery-policy.json`.
2. Create role `stockwatch-dr-readonly-discovery` with trust policy `docs/aws/ec2-trust-policy.json`, attach the policy (the console creates the instance profile automatically).
3. EC2 → instance `i-07590867e7e49c18b` → Actions → Security → Modify IAM role → select the role. **No reboot or restart is required.**
4. Tell me when done. I will then install AWS CLI v2 (official package + GPG signature verification) and run read-only discovery only.

## Commands I will run once access exists (all read-only)

```bash
aws sts get-caller-identity
aws rds describe-db-instances --db-instance-identifier stockwatch-primary-db --region ap-southeast-2 \
  --query 'DBInstances[0].{Engine:EngineVersion,Class:DBInstanceClass,MultiAZ:MultiAZ,Encrypted:StorageEncrypted,Kms:KmsKeyId,Retention:BackupRetentionPeriod,Window:PreferredBackupWindow,LatestRestorable:LatestRestorableTime,Public:PubliclyAccessible,DeletionProtection:DeletionProtection,ManagedSecret:MasterUserSecret,SGs:VpcSecurityGroups,Subnets:DBSubnetGroup.DBSubnetGroupName,CA:CACertificateIdentifier}'
aws secretsmanager describe-secret --secret-id <MasterUserSecret ARN> --region ap-southeast-2 \
  --query '{RotationEnabled:RotationEnabled,Rules:RotationRules,LastRotated:LastRotatedDate,Next:NextRotationDate}'
aws rds describe-source-regions --region ap-southeast-4
aws rds describe-orderable-db-instance-options --engine postgres --engine-version 16.15 --db-instance-class db.t4g.micro --region ap-southeast-4 --query 'length(OrderableDBInstanceOptions)'
aws ec2 describe-instances --instance-ids i-07590867e7e49c18b --region ap-southeast-2
aws ec2 describe-security-groups --filters Name=vpc-id,Values=vpc-02371e067f7e28e42 --region ap-southeast-2
aws route53 list-hosted-zones; aws route53domains list-domains --region us-east-1
```

## Future permissions (NOT requested now)

Phase 4 needs a separate, scoped **operator** policy, requested at that approval gate: e.g. `rds:ModifyDBInstance` (backup retention) on the primary ARN only, `rds:CreateDBInstanceReadReplica` / `PromoteReadReplica` / `RestoreDBInstanceToPointInTime` restricted to `stockwatch-*` identifiers, `route53:ChangeResourceRecordSets` on one hosted zone, Terraform-state S3 bucket access, and tag-conditioned EC2/VPC create/delete in the DR region. Destructive actions (`rds:DeleteDBInstance`, `ec2:TerminateInstances`) would be limited by tag `Project=stockwatch-dr` and never applied to the primary.
