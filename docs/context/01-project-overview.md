# 01 — Project Overview

## What this is

StockWatch is a lightweight inventory monitoring and low-stock alert system. It is the demonstration application for the VEGAH DevOps / Cloud Engineering Intern practical assessment.

## Guiding principle

Application functionality should be minimal; infrastructure implementation should be complete.

The assessment weighting is Docker 20%, CI/CD 25%, Cloud 20%, Redis worker 15%, security/reliability 10%, and documentation 10%. Prioritize accordingly.

## Problem and solution

Businesses maintain inventory records but may miss when products reach critically low stock. StockWatch stores inventory and lets a user manually run a stock check. The check runs asynchronously:

NestJS API → Redis/BullMQ queue → separate worker → PostgreSQL.

The dashboard displays job status, results, and history.

## Example

| Item | Quantity | Minimum | Expected status |
|---|---:|---:|---|
| Wireless Mouse | 3 | 10 | Low stock |
| Keyboard | 25 | 10 | Healthy |
| USB Hub | 4 | 5 | Low stock |
| Monitor | 12 | 8 | Healthy |

The rule is `quantity <= minQuantity` means low stock.

## Out of scope

Do not build authentication, registration, roles, email notifications, supplier management, purchase orders, advanced analytics, Kubernetes, multiple application servers, or managed PostgreSQL/Redis unless the assessment environment forces a change. Terraform is optional and not required.

## Ownership constraint

AI-generated code is allowed, but the candidate must understand and explain every important part, especially Docker, CI/CD, cloud deployment, secrets, persistence, and troubleshooting.
