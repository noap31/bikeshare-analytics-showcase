# Zen City Bike-Share Analytics — Q1 2022

A SQL-driven analysis of a docked bike-share system's first quarter of 2022, built to answer a concrete strategy question: **how should Zen City improve station placement, fleet mix, and customer targeting ahead of Q2?**

Everything in this repo — the data-cleaning pipeline, the revenue model, the station-risk scoring, and the customer segmentation — runs in **BigQuery Standard SQL**, with statistical testing (Kruskal-Wallis, post-hoc pairwise comparisons) done downstream once BigQuery's aggregates were exported.

**[Read the full findings write-up →](./findings.md)**

## Team & my role

This was a 3-person team capstone project for the Google & Reichman University AI Tech School Data Analyst Program (team: Noa Palevsky, Dolae Arbaieter, Yael Levi).

## The business questions

1. **Station usage** — which stations are commuter-driven, which are recreational, and how should that shape relocation, expansion, and marketing decisions?
2. **Net flow & rebalancing risk** — which stations create the most operational pressure by chronically emptying out or filling up?
3. **Customer segments & profitability** — which subscriber segments generate the most estimated revenue, and which provide the most stable base?
4. **Fleet mix** — does the current classic/electric bike split actually match rider demand?

## What's in this repo

| File | What it is |
|---|---|
| [`zen_city_bikeshare_analysis.sql`](./zen_city_bikeshare_analysis.sql) | The full SQL pipeline: raw data exploration, a reusable cleaning + trip-revenue CTE chain, and every downstream analysis query, each with a detailed explanation of the business question and method behind it. |
| [`findings.md`](./findings.md) | The results write-up — what the queries found, with the real numbers and charts behind each claim. |
| `01_...png` – `09_...png` | Chart images referenced in the findings write-up (kept in the same folder as everything else, not a subfolder). |

## Data

Three BigQuery tables back this analysis:

- **`rentals`** — one row per trip: start/end station, start time, duration, bike type/ID, subscriber type, customer ID.
- **`station_info`** — one row per station: dock count, address, council district, open/closed status.
- **`customers`** — rider demographics (age, gender).

The raw data turned out to need real cleanup before it was trustworthy: station IDs were swapped or duplicated between `rentals` and `station_info` (traced in detail in the SQL file and findings write-up), a handful of station addresses held corporate-sponsorship labels instead of real street addresses, and two stations were silently missing entire months of records rather than showing up as an error.

## Method highlights

- **ID reconciliation** — station counts shifted from 81 → 82 → 85 across three successive join attempts before the real picture (swapped and duplicated IDs) became clear; every fix is documented inline in the SQL.
- **A recursive CTE** tracks each customer's time-boxed passes (24-hour / weekend) so only the *first* ride under an active pass is billed, and every ride after it until expiry is free — matching the real pricing policy rather than charging per trip.
- **Reverse-engineering per-trip revenue from the pricing policy, not observed billing** — there's no transaction/billing table in this dataset, so every dollar figure is rebuilt from scratch per trip: a base unlock fee that depends on subscriber type, a free-ride window that varies by plan (60 minutes for annual/student/weekend passes, 30 minutes for monthly/24-hour passes), and overage minutes rounded up to the next 30-minute billing block before the per-block rate applies — then carried further still, into real active-member counts (Part F.1/F.3) multiplied by actual pass prices to estimate prepaid subscription revenue on top of it.
- **Net-flow risk model** — an hour-by-hour master calendar (to avoid survivorship bias from missing hours), anomaly quarantining (dropping storm/outage days), and a propagated 95% confidence interval on cumulative net flow to flag stations at real risk of running empty or full.
- **Statistical testing** — a Kruskal-Wallis test plus Bonferroni-corrected pairwise Mann-Whitney U tests to confirm ride-duration differences between membership segments are real, not noise.
- **Testing an alternative explanation before recommending anything** — before recommending a fleet-mix change based on classic bikes' low usage, traced each bike's last known parked location against how busy that station is, to rule out "they're just parked in the wrong place" as a simpler explanation.

## Key findings (short version — full detail in [findings.md](./findings.md))

- Students are 77.5% of total trips but only 17.4% of total estimated *per-ride* revenue — at $0.38/ride they're close to a break-even segment, while Short-Term and Single-Trip riders pay 25-30x more per ride and together drive over half of revenue from under 10% of trips. But that's only the per-trip view: adding in what riders pay for the membership itself (pass fees × real active-member counts), Students are an estimated 48.8% of total revenue and Monthly riders jump to 27.4% — both far larger than their per-trip numbers alone suggest, because so much of the rider base holds a student or monthly pass. Both views are real, they're just answering different questions (see findings.md for the full breakdown and both charts). (Revenue throughout this project is modeled from pricing rules applied to subscriber type and duration — there's no observed billing data — so every revenue figure and chart is labeled "estimated" rather than treated as recorded income.)
- The system is structurally imbalanced: several stations consistently behave as "sinkholes" (bikes pile up, rarely depart) or chronic deficits, a real and quantifiable rebalancing cost.
- The current fleet is nearly 50/50 classic vs. electric by bike count, but electric bikes carry roughly 7x the ride volume — a mismatch between fleet mix and actual demand.
- 25% of the fleet generates fewer than 5 rides each over the study period, and that under-used group is almost entirely classic bikes. Tested against the obvious alternative explanation (classic bikes just parked at quiet stations) and ruled it out: classic and electric bikes sit across busy vs. quiet stations in almost identical proportions, yet classic bikes still underperform badly even at the busiest stations — a real rider-preference signal, not a placement problem.
- Younger male riders (Gen Z and Young Professional) ride at meaningfully lower volume than same-age women despite near-identical ride durations — pointing to an acquisition gap, not a usage-pattern difference.

## Caveats & limitations

- Several thresholds (the 60-ride/day anomaly cutoff, the 0.35/0.20 weekend-ratio station-profile split, and the 75%-of-docks imbalance threshold) are reasoned choices grounded in the data's own distribution, not universal constants — see the SQL comments and findings write-up for the reasoning behind each.
- The net-flow risk model has no visibility into the company's own rebalancing activity (staff/trucks physically moving bikes between stations), so it measures relative demand pressure — how far a station's balance would drift if nothing intervened — rather than a validated, absolute "ran out of bikes/docks" event.
- `customer_id` is a synthetic add-on to the underlying public Austin B-cycle dataset this project is built on, which has no real customer-level tracking — it appears to have been assigned per ride fairly arbitrarily, without regard to that ride's own subscriber type. That's the most likely root cause of the customer-membership-switching pattern flagged in Part F.1 of the SQL (individual customers appearing to hold five different membership types within days of each other), which is why membership revenue in this project is built from real per-trip data and real active-member counts rather than from any single per-customer "membership type" label.
