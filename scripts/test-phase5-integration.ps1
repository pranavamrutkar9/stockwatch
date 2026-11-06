# Phase 5 Local Integration Test Script
$ErrorActionPreference = "Stop"

Write-Host "=== Phase 5 Local Integration Test ===" -ForegroundColor Cyan

$BaseUrl = "http://localhost:3000/api"

# 1. Health check
Write-Host "1. Testing /api/health through frontend proxy..." -NoNewline
$health = Invoke-RestMethod -Uri "$BaseUrl/health" -Method Get
if ($health.status -eq "ok" -and $health.dependencies.database -eq "connected" -and $health.dependencies.redis -eq "connected") {
    Write-Host " PASS" -ForegroundColor Green
} else {
    Write-Host " FAIL" -ForegroundColor Red
    exit 1
}

# 2. Create inventory items
Write-Host "2. Creating inventory items..." -NoNewline
$sku1 = "TEST-LOW-" + (Get-Random -Minimum 1000 -Maximum 9999)
$sku2 = "TEST-OK-" + (Get-Random -Minimum 1000 -Maximum 9999)

$body1 = @{
    name = "Test Low Stock Item"
    sku = $sku1
    quantity = 3
    minQuantity = 10
    category = "Hardware"
} | ConvertTo-Json

$item1 = Invoke-RestMethod -Uri "$BaseUrl/inventory" -Method Post -Body $body1 -ContentType "application/json"
if ($item1.sku -eq $sku1 -and $item1.status -eq "LOW_STOCK") {
    Write-Host " Item 1 (LOW_STOCK) OK;" -ForegroundColor Green -NoNewline
} else {
    Write-Host " Item 1 FAIL" -ForegroundColor Red
    exit 1
}

$body2 = @{
    name = "Test Healthy Item"
    sku = $sku2
    quantity = 50
    minQuantity = 10
    category = "Hardware"
} | ConvertTo-Json

$item2 = Invoke-RestMethod -Uri "$BaseUrl/inventory" -Method Post -Body $body2 -ContentType "application/json"
if ($item2.sku -eq $sku2 -and $item2.status -eq "HEALTHY") {
    Write-Host " Item 2 (HEALTHY) OK;" -ForegroundColor Green -NoNewline
} else {
    Write-Host " Item 2 FAIL" -ForegroundColor Red
    exit 1
}

# 3. Test conflict on duplicate SKU
Write-Host " Duplicate SKU Conflict..." -NoNewline
try {
    Invoke-RestMethod -Uri "$BaseUrl/inventory" -Method Post -Body $body1 -ContentType "application/json"
    Write-Host " FAIL (expected 409)" -ForegroundColor Red
    exit 1
} catch {
    if ($_.Exception.Response.StatusCode.value__ -eq 409) {
        Write-Host " PASS (409 Conflict)" -ForegroundColor Green
    } else {
        Write-Host " FAIL (Unexpected status code: $($_.Exception.Response.StatusCode.value__))" -ForegroundColor Red
        exit 1
    }
}

# 4. Trigger stock check (Normal Mode)
Write-Host "3. Triggering asynchronous Stock Check..." -NoNewline
$triggerRes = Invoke-RestMethod -Uri "$BaseUrl/stock-checks" -Method Post -Body "{}" -ContentType "application/json"
if (-not $triggerRes.id -or -not $triggerRes.jobId) {
    Write-Host " FAIL (No jobId or id returned)" -ForegroundColor Red
    exit 1
}
$checkId = $triggerRes.id
Write-Host " PASS (Check ID: $checkId, Job ID: $($triggerRes.jobId))" -ForegroundColor Green

# 5. Poll for completion
Write-Host "4. Polling Stock Check until COMPLETED..." -NoNewline
$completed = $false
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Seconds 1
    $statusRes = Invoke-RestMethod -Uri "$BaseUrl/stock-checks/$checkId" -Method Get
    if ($statusRes.status -eq "COMPLETED") {
        $completed = $true
        Write-Host " COMPLETED in $($i + 1)s!" -ForegroundColor Green
        Write-Host "   Total Checked: $($statusRes.totalChecked), Low Stock Count: $($statusRes.lowStockCount)" -ForegroundColor Gray
        break
    } elseif ($statusRes.status -eq "FAILED") {
        Write-Host " FAILED with error: $($statusRes.error)" -ForegroundColor Red
        exit 1
    }
}

if (-not $completed) {
    Write-Host " TIMEOUT waiting for job completion" -ForegroundColor Red
    exit 1
}

# 6. Verify alert generated
Write-Host "5. Verifying Low Stock Alert in /api/alerts..." -NoNewline
$alerts = Invoke-RestMethod -Uri "$BaseUrl/alerts" -Method Get
$matchingAlert = $alerts | Where-Object { $_.inventoryItemId -eq $item1.id }
if ($matchingAlert) {
    Write-Host " PASS (Alert ID: $($matchingAlert.id), Item: $($matchingAlert.inventoryItem.name))" -ForegroundColor Green
} else {
    Write-Host " FAIL (No alert found for item 1)" -ForegroundColor Red
    exit 1
}

# 7. Test Failure Simulation Mode
Write-Host "6. Testing failure simulation mode (WORKER_SIMULATE_FAILURE=true)..." -ForegroundColor Yellow
docker-compose -f infrastructure/docker/docker-compose.yml stop worker | Out-Null
docker rm -f stockwatch-worker-fail 2>$null | Out-Null
docker-compose -f infrastructure/docker/docker-compose.yml run -d --name stockwatch-worker-fail -e WORKER_SIMULATE_FAILURE=true worker | Out-Null

Start-Sleep -Seconds 3

Write-Host "   Triggering stock check during failure mode..." -NoNewline
$failTrigger = Invoke-RestMethod -Uri "$BaseUrl/stock-checks" -Method Post -Body "{}" -ContentType "application/json"
$failCheckId = $failTrigger.id

$failedAsExpected = $false
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Seconds 1
    $failStatus = Invoke-RestMethod -Uri "$BaseUrl/stock-checks/$failCheckId" -Method Get
    if ($failStatus.status -eq "FAILED") {
        $failedAsExpected = $true
        Write-Host " PASS (Status: FAILED, Error: '$($failStatus.error)')" -ForegroundColor Green
        break
    }
}

# Cleanup failure container & restart normal worker
docker rm -f stockwatch-worker-fail | Out-Null
docker-compose -f infrastructure/docker/docker-compose.yml start worker | Out-Null

if (-not $failedAsExpected) {
    Write-Host " FAIL: Stock check did not transition to FAILED as expected" -ForegroundColor Red
    exit 1
}

# 8. Test PostgreSQL Persistence across container restart
Write-Host "7. Testing PostgreSQL persistence across container restart..." -NoNewline
docker restart stockwatch-postgres | Out-Null
Start-Sleep -Seconds 6

$inventoryAfterRestart = Invoke-RestMethod -Uri "$BaseUrl/inventory" -Method Get
$found1 = $inventoryAfterRestart | Where-Object { $_.sku -eq $sku1 }
$found2 = $inventoryAfterRestart | Where-Object { $_.sku -eq $sku2 }

if ($found1 -and $found2) {
    Write-Host " PASS (Data persisted across postgres restart)" -ForegroundColor Green
} else {
    Write-Host " FAIL (Inventory missing after postgres restart)" -ForegroundColor Red
    exit 1
}

Write-Host "=== All Phase 5 Integration and Failure Tests PASSED ===" -ForegroundColor Green
