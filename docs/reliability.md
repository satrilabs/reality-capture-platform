# Reliability: what we promise and how we know

Service level objectives for the three things a customer notices. Each one is measured from the customer's side, over a rolling 28 days.

| What the customer does | Measured as (SLI) | Target (SLO) | Error budget per 28 days |
|---|---|---|---|
| Uploads a scan | Upload sessions that complete without a server error | 99.9% | about 40 minutes of failures |
| Waits for it to be processed | Scans processed within 30 minutes of the upload completing | 99% | 1 in 100 scans may take longer |
| Opens a project in the viewer | Viewer and API requests answered without a 5xx, under 2 seconds | 99.9% | about 40 minutes of failures |

## Error budget policy

- **Less than half the budget used:** ship as normal.
- **More than half used:** risky changes to that service wait; the team works on the cause first.
- **Budget gone:** only fixes and reliability work for that service until the 28-day window recovers.

The budget turns "is it reliable enough?" from an argument into a number both the platform team and the product teams agreed on.

## Alerts: on symptoms, not on causes

Nobody is paged for high CPU. People are paged when customers are failing faster than the budget allows. Multi-window burn-rate alerts, for each SLO:

| Alert | Fires when | Means |
|---|---|---|
| Page | 2% of the 28-day budget burned in 1 hour, still burning over the last 5 minutes | at this rate the budget is gone in about 2 days |
| Page | 5% burned in 6 hours, still burning over the last 30 minutes | a slower but real outage: the budget would last about 5 days |
| Ticket | 10% burned in 3 days | something degraded quietly |
| Ticket | any message on a dead-letter queue | a scan failed five times and needs a person |

The short second window stops alerts from firing long after a problem has already recovered.

## Telemetry

Services emit traces, metrics and logs with OpenTelemetry and send them over OTLP to a collector, which forwards them to the observability backend (Elastic or Azure Monitor; the services do not care which). The processor reports, per scan:

- a trace span `scan.process`, with the scan size and a hashed project ID, never customer names;
- a duration histogram `scan_processing_seconds`, which the processing SLO is computed from;
- counters for processed and failed scans.

## Recovery

- **Mistakes** (a deleted or overwritten scan): blob versioning and 30-day soft delete; restore without a backup system.
- **A datacentre down:** zone-redundant storage and Service Bus keep running in the other zones.
- **A region down:** the other region's customers are unaffected, because stamps share nothing. Customers of the failed region wait for Azure, or, for tiers that opted into geo-redundancy, fail over to the paired region, which stays inside the same data region.
- **Drills:** restores are tested on a schedule, and the time it took is recorded, so the recovery time in a runbook is measured, not hoped for.
