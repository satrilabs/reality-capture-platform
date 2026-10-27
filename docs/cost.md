# Cost notes

Scan data is written once, read heavily while a project is active, then rarely. The platform is built so that cost per customer stays flat as the number of customers grows.

## What a terabyte of scans costs

Azure list prices for block blob storage, first price tier, from the [Azure Retail Prices API](https://learn.microsoft.com/rest/api/cost-management/retail-prices/azure-retail-prices) on 27 October 2026, in EUR per TB per month (1 TB = 1,024 GB):

| Tier | West Europe | East US 2 |
|---|---|---|
| Hot, zone-redundant (ZRS) | 21.61 | 20.68 |
| Cool, ZRS | 11.78 | 11.26 |
| Cold, ZRS | 4.51 | 3.58 |
| Archive, locally redundant (LRS) | 1.64 | 1.84 |
| Hot, geo-zone-redundant (GZRS) | 41.47 | 37.27 |

Storage is only part of the bill: reads, writes and early-deletion charges are higher in the colder tiers (cool has a 30-day minimum, cold 90 days), and data leaving Azure is charged separately.

## The tiering rule, in numbers

One terabyte of scans kept for a year in West Europe, stored only:

| Policy | Months hot / cool / cold | EUR per year |
|---|---|---|
| Everything stays hot | 12 / 0 / 0 | 259 |
| The lifecycle rule in `region-stamp` (cool after 30 days, cold after 90 without access) | 1 / 2 / 9 | 86 |

About two thirds less, for a project nobody opens after the first month. A reopened project moves back to hot on the first read, so customers never wait for a restore.

Archive would be cheaper still, but it is not offered on zone-redundant accounts. Projects closed for over a year can be moved to a separate locally redundant archive account in the same region (1.64 EUR per TB).

## The levers, ranked for this workload

1. **Storage tiering** by last access, as above. The largest line item grows with every scanner sold.
2. **Zone-redundant by default, geo-redundant on purpose.** GZRS roughly doubles the storage price (41.47 against 21.61). The policy warns on it and asks for a `replication-reason` tag.
3. **Spot capacity for build agents and batch processing.** Spot VMs are typically far cheaper than regular ones; builds and queue-driven processing can be retried after an eviction.
4. **Scale to zero.** Build agents and processors exist only while there is work in the queue.
5. **Log caps.** Each stamp's Log Analytics workspace has a daily ingestion cap, so one noisy service cannot run up the bill.
6. **Egress.** Viewer traffic goes through Front Door, where caching keeps repeated downloads of the same tiles from leaving storage every time.

## Cost per customer

Every resource carries `owner`, `cost-center` and `data-region` tags, enforced by policy, so Azure Cost Management can group spend by team and region. Storage is the part that grows per customer: with one prefix per customer project inside the scan containers, storage inventory reports give bytes per customer and tier, which turns into a monthly cost per customer.
