/* ============================================================================
   ZEN CITY BIKE-SHARE ANALYTICS — Q1 2022
   BigQuery Standard SQL

   Business context: Zen City is a bike-share system (Austin-style docked
   fleet of classic + electric bikes). This file answers a Q1 2022 strategy
   review covering four themes: (A) raw data discovery and quality issues,
   (B) a reusable data-cleaning + trip-revenue engine, (C) seasonality/
   timeline patterns, (D) fleet utilization, (E) station-level operations
   (profiling + rebalancing risk), and (F) customer segmentation.

   Tables referenced (project `bqproj-488319`, dataset `zen_city`):
     - rentals        one row per trip (start/end station+time, bike, rider)
     - station_info    dimension table: docks, address, status per station
     - customers       rider demographics (age, gender)

   HOW THIS FILE IS ORGANIZED
   ---------------------------------------------------------------------------
   Part A is raw exploration — runs directly against the source tables, no
   dependencies.

   Part B is the single shared CTE chain every later query builds on: it
   fixes station-ID mismatches, standardizes names/addresses, filters bad
   trips, buckets subscription types into 5 membership groups, and computes
   per-trip revenue. It ends with a demo SELECT so it can be run standalone.

   Parts C–F are all *continuations* of Part B's WITH clause (BigQuery only
   allows one WITH per query, so they can't be pasted as separate statements
   after it). To run any query in Parts C–F:
     1. Copy Part B's `WITH RECURSIVE ... trip_revenue_to_clean_rentals AS ( ... )`
     2. Replace the closing `)` + demo SELECT with `),`
     3. Paste the section's CTE(s) and final SELECT directly after
   Each section header below notes exactly which upstream CTE(s) it needs.
   ============================================================================ */


/* ============================================================================
   PART A — RAW DATA EXPLORATION & QUALITY DISCOVERY
   Run directly against the source tables. No cleaning applied yet — the goal
   here is to find the problems that Part B then fixes.
   ============================================================================ */

-- A.1 — What end stations exist in the raw trip log, and under what IDs?
-- First pass at understanding station coverage before touching the
-- dimension table.
SELECT DISTINCT
  end_station_name,
  end_station_id
FROM `bqproj-488319.zen_city.rentals`
ORDER BY end_station_name;


-- A.2 — Do all end-station IDs in the trip log actually exist in the
-- station dimension table? A LEFT JOIN that returns NULLs on the right
-- side is the first signal of an ID mismatch.
SELECT DISTINCT
  r.end_station_name,
  r.end_station_id,
  si.name
FROM `bqproj-488319.zen_city.rentals` r
LEFT JOIN `bqproj-488319.zen_city.station_info` si
  ON r.end_station_id = si.station_id;


-- A.3 — A.2 came back with nulls, so here we also try joining on station
-- NAME (in addition to ID) to see whether the mismatch is an ID problem,
-- a naming problem, or both. This single query is how the ID-swap and
-- duplicate-ID issues documented in Table 4 of the report were first
-- surfaced: distinct station counts moved from 81 (grouping by ID alone)
-- to 82 (also grouping by name) to 85 (after this three-way join) —
-- proof that some stations carry more than one ID, and some IDs are
-- shared/duplicated across stations.
WITH end_station AS (
  SELECT
    end_station_id,
    end_station_name,
    COUNT(*) AS number_of_rides,
    CASE
      WHEN end_station_id IN (
        SELECT DISTINCT start_station_id FROM `bqproj-488319.zen_city.rentals`
      ) THEN 'also_in_start'
      ELSE 'not_in_start'
    END AS check_if_in_start
  FROM `bqproj-488319.zen_city.rentals`
  GROUP BY end_station_id, end_station_name
)
SELECT
  r.end_station_id,
  r.end_station_name,
  si.station_id,
  si.name,
  r.number_of_rides,
  r.check_if_in_start,
  si.status,
  si.notes,
  si.number_of_docks
FROM end_station r
LEFT JOIN `bqproj-488319.zen_city.station_info` si
  ON r.end_station_id = si.station_id
  OR r.end_station_name = REPLACE(si.name, ' & ', '/')
  OR r.end_station_name = REPLACE(si.name, '22nd 1/2 & Rio Grande', '22.5/Rio Grande')
ORDER BY r.number_of_rides DESC;


-- A.4 — Station dimension table shape: how many stations exist, how big is
-- the average dock count, and what fraction are already marked closed?
-- (COUNTIF is BigQuery's shorthand for COUNT(CASE WHEN ... THEN 1 END).)
SELECT
  COUNT(*) AS number_of_stations,
  AVG(number_of_docks) AS average_docks_per_station,
  MAX(number_of_docks) AS max_docks_per_station,
  MIN(number_of_docks) AS min_docks_per_station,
  COUNT(council_district) AS stations_with_district_info,
  COUNTIF(status = 'closed') AS number_of_closed_stations,
  COUNTIF(status = 'active') AS number_of_active_stations
FROM `bqproj-488319.zen_city.station_info`;


-- A.5 — Fleet composition: how many bikes of each type exist, and how many
-- rides has each type actually generated? (This is the first hint that
-- electric bikes handle a disproportionate share of demand — see Part D.)
SELECT
  bike_type,
  COUNT(DISTINCT bike_id) AS bike_amount,
  COUNT(*) AS number_of_rides
FROM `bqproj-488319.zen_city.rentals`
GROUP BY bike_type;


/* ============================================================================
   PART B — SHARED DATA-CLEANING & TRIP-REVENUE ENGINE
   Every query in Parts C–F is built on top of this CTE chain. Read this
   section once; everything downstream assumes it.
   ============================================================================ */

WITH RECURSIVE

-- B.1 cleaned_rentals: the core trip-level cleaning step.
--   - Consolidates station IDs: Part A's investigation found stations that
--     were swapped or duplicated between the trip log and the station
--     dimension table (full list in Table 4 of the report, e.g.
--     4th/Sabine <-> Dean Keeton/Speedway had their IDs swapped). This CASE
--     re-maps every affected start/end ID onto the ID used in the
--     dimension table, so joins downstream are reliable.
--   - Buckets the ~11 raw `subscriber_type` values into 5 business-meaningful
--     membership groups (Annual, Monthly, Short-Term, Single Trip, Student).
--   - Filters out two kinds of noise: false-start round trips under 3
--     minutes (likely a rider undocking/redocking at the same station
--     rather than a real ride), and trips over 10 hours (bike left
--     unlocked / stolen / never properly ended).
--   - Adds the time features (hour, day name, weekday/weekend) used by
--     almost every downstream query.
cleaned_rentals AS (
  SELECT
    trip_id,
    customer_id,
    subscriber_type,
    start_time,
    TIMESTAMP_ADD(start_time, INTERVAL duration_minutes MINUTE) AS end_time,
    duration_minutes,
    start_station_name,
    end_station_name,
    bike_type,
    bike_id,

    CASE
      WHEN subscriber_type IN ('Local365', 'Annual Membership', 'Founder Member') THEN 'Annual'
      WHEN subscriber_type IN ('Local31', 'Monthly Membership') THEN 'Monthly'
      WHEN subscriber_type IN ('Explorer', 'Weekend Pass', '3-Day Weekender', '24-Hour Pass') THEN 'Short-Term'
      WHEN subscriber_type = '24 Hour Walk Up Pass' THEN 'Short-Term'
      WHEN subscriber_type IN ('Single Trip', 'Pay-as-you-ride', 'Single Trip (Pay-as-you-ride)') THEN 'Single Trip'
      WHEN subscriber_type LIKE '%Student%' THEN 'Student'
      WHEN subscriber_type = 'HT Ram Membership' THEN 'Student'
      ELSE 'Other'
    END AS membership_group,

    -- Consolidate legacy / swapped / duplicate station IDs onto the ID
    -- used in the station_info dimension table (see Table 4 in the report).
    CASE
      WHEN start_station_id = 2498 THEN 3794   -- 4th/Sabine <-> Dean Keeton/Speedway swap
      WHEN start_station_id = 3794 THEN 2498
      WHEN start_station_id IN (3455, 2550) THEN 2550   -- Republic Square, moved back to 4th/Guadalupe
      WHEN start_station_id = 4938 THEN 11              -- 22.5/Rio Grande
      WHEN start_station_id = 7125 THEN 111             -- 23rd/San Gabriel
      WHEN start_station_id IN (7188, 3792) THEN 3792   -- 22nd/Pearl (two IDs -> one)
      WHEN start_station_id = 7131 THEN 1111            -- 13th/Trinity
      WHEN start_station_id = 7190 THEN 2545            -- Rio Grande/12th (closed)
      WHEN start_station_id = 7187 THEN 0               -- South Congress/Mary (low-volume, left as 0 for now)
      ELSE start_station_id
    END AS start_id_fixed,

    CASE
      WHEN end_station_id = 2498 THEN 3794
      WHEN end_station_id = 3794 THEN 2498
      WHEN end_station_id IN (3455, 2550) THEN 2550
      WHEN end_station_id = 4938 THEN 11
      WHEN end_station_id = 7125 THEN 111
      WHEN end_station_id IN (7188, 3792) THEN 3792
      WHEN end_station_id = 7131 THEN 1111
      WHEN end_station_id = 7190 THEN 2545
      WHEN end_station_id = 7187 THEN 0
      ELSE end_station_id
    END AS end_id_fixed,

    EXTRACT(HOUR FROM start_time) AS hour_of_day,
    FORMAT_DATE('%A', DATE(start_time)) AS day_name,
    CASE WHEN EXTRACT(DAYOFWEEK FROM start_time) IN (1, 7) THEN 'Weekend' ELSE 'Weekday' END AS day_type

  FROM `bqproj-488319.zen_city.rentals`
  WHERE NOT (duration_minutes <= 3 AND start_station_id = end_station_id)  -- drop false-start round trips
    AND duration_minutes < 600                                             -- drop >10hr abandoned/stolen bikes
),

-- B.2 cleaned_station_info: standardizes station names (decimal + symbol
-- conventions) and restores real street addresses for the handful of rows
-- where the address column actually held a corporate sponsorship label
-- (e.g. "Presented by Whole Foods") instead of a usable address — needed
-- for the geographic clustering in Part E.
cleaned_station_info AS (
  SELECT
    *,
    REGEXP_REPLACE(REPLACE(name, '22nd 1/2', '22.5'), r' [&\@] ', ' / ') AS clean_name,
    CASE
      WHEN address LIKE '%Whole Foods%' THEN '525 N Lamar Blvd'
      WHEN address LIKE '%Parks Foundation%' THEN '1100 Kingsbury St'
      WHEN address LIKE '%Austin Chronicle%' THEN '400 Guadalupe St'
      WHEN address LIKE '%Austin Energy%' THEN '211 Nickerson St'
      WHEN address LIKE '%Graves Dougherty%' THEN '300 E 11th St'
      WHEN address IS NULL OR address = '' THEN 'Address Unknown'
      ELSE address
    END AS clean_address
  FROM `bqproj-488319.zen_city.station_info`
),

-- B.3 short_term_trips: isolates every trip made under a time-boxed pass
-- (24-hour or weekend/72-hour), numbered per customer in chronological
-- order. This feeds the recursive pass tracker below, because a pass only
-- charges an unlock fee on its *first* use within its validity window —
-- every ride after that, until the pass expires, is free.
short_term_trips AS (
  SELECT
    trip_id,
    customer_id,
    subscriber_type AS subscription_type,
    start_time,
    ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY start_time) AS row_num
  FROM cleaned_rentals
  WHERE subscriber_type IN (
    '24-Hour Pass', '24 Hour Walk Up Pass', 'Explorer',
    'Weekend Pass', '3-Day Weekender', 'ACL Weekend Pass'
  )
),

-- B.4 pass_tracker: a recursive CTE that walks each customer's short-term
-- trips in order and carries forward the pass's expiry time. Each new trip
-- either falls inside the still-active pass window (rn_24h/rn_72h = 2+,
-- free) or starts a brand-new pass window (rn_24h/rn_72h = 1, charged).
-- This is the mechanism that makes "first ride under this pass" billable
-- and every ride after it, until expiry, free.
pass_tracker AS (
  -- Anchor: each customer's first short-term trip always starts a fresh pass.
  SELECT
    trip_id, customer_id, subscription_type, start_time, row_num,
    TIMESTAMP_ADD(start_time, INTERVAL 24 HOUR) AS pass_24h_exp,
    TIMESTAMP_ADD(start_time, INTERVAL 72 HOUR) AS pass_72h_exp,
    1 AS rn_24h,
    1 AS rn_72h
  FROM short_term_trips
  WHERE row_num = 1

  UNION ALL

  -- Recursive step: for each subsequent trip, check whether it lands after
  -- the running pass expiry (renew it, rn = 1) or still inside it (rn = 2+).
  SELECT
    t.trip_id, t.customer_id, t.subscription_type, t.start_time, t.row_num,
    CASE WHEN t.start_time > p.pass_24h_exp THEN TIMESTAMP_ADD(t.start_time, INTERVAL 24 HOUR) ELSE p.pass_24h_exp END,
    CASE WHEN t.start_time > p.pass_72h_exp THEN TIMESTAMP_ADD(t.start_time, INTERVAL 72 HOUR) ELSE p.pass_72h_exp END,
    CASE WHEN t.start_time > p.pass_24h_exp THEN 1 ELSE 2 END,
    CASE WHEN t.start_time > p.pass_72h_exp THEN 1 ELSE 2 END
  FROM pass_tracker p
  JOIN short_term_trips t
    ON t.customer_id = p.customer_id
   AND t.row_num = p.row_num + 1
),

-- B.5 priced_trips_base: attaches the pricing rules to every trip —
-- subscription/annual/student plans pay $0 to unlock (they've already
-- paid via membership), time-boxed passes pay their access fee only on
-- first use (per pass_tracker above), and everything else pays a flat
-- $3.50 unlock fee. Also attaches each subscriber type's free-ride window
-- (60 min for annual/student/weekend passes, 30 min for monthly/24-hour
-- passes, 0 for pure pay-as-you-go) and the system-wide overage rate.
priced_trips_base AS (
  SELECT
    r.*,
    r.subscriber_type AS subscription_type,

    CASE
      WHEN r.subscriber_type IN (
        'Local365', 'Annual Membership', 'Annual', 'Monthly Membership', 'Monthly', 'Founder Member',
        'Student Membership', 'UT Student Membership', 'HT Ram Membership'
      ) THEN 0.00
      WHEN r.subscriber_type IN ('24-Hour Pass', '24 Hour Walk Up Pass', 'Explorer') AND pt.rn_24h = 1 THEN 10.00
      WHEN r.subscriber_type IN ('24-Hour Pass', '24 Hour Walk Up Pass', 'Explorer') AND pt.rn_24h > 1 THEN 0.00
      WHEN r.subscriber_type IN ('Weekend Pass', '3-Day Weekender', 'ACL Weekend Pass') AND pt.rn_72h = 1 THEN 15.00
      WHEN r.subscriber_type IN ('Weekend Pass', '3-Day Weekender', 'ACL Weekend Pass') AND pt.rn_72h > 1 THEN 0.00
      ELSE 3.50
    END AS base_unlock_fee,

    CASE
      WHEN subscriber_type IN (
        'Local365', 'Annual Membership', 'Annual', 'Founder Member',
        'Student Membership', 'UT Student Membership', 'HT Ram Membership',
        'Weekend Pass', '3-Day Weekender', 'ACL Weekend Pass'
      ) THEN 60
      WHEN subscriber_type IN (
        'Local31', 'Monthly Membership', 'Monthly',
        '24-Hour Pass', '24 Hour Walk Up Pass', 'Explorer', 'Single Ride (B-cycle Members Only)'
      ) THEN 30
      ELSE 0
    END AS free_window_minutes,

    4.00 AS overage_rate_per_30_min

  FROM cleaned_rentals r
  LEFT JOIN pass_tracker pt ON r.trip_id = pt.trip_id
),

-- B.6 trip_revenue_to_clean_rentals: the final per-trip revenue formula.
-- Minutes beyond the free window are rounded UP to the next 30-minute
-- billing block (a rider who's 1 minute over pays for a full block, same
-- as the real pricing policy in Table 5), then billed at the overage rate
-- on top of the base unlock fee.
-- IMPORTANT: there's no observed billing/transaction data in this dataset
-- — every dollar figure from here on (estimated_trip_revenue and everything
-- built from it: station revenue, membership revenue, demographic revenue)
-- is MODELED from the pricing rules above applied to subscriber type and
-- duration, not a real recorded charge. All downstream column names carry
-- an "estimated_" prefix as a reminder — keep that prefix (or an equivalent
-- label) on any chart title or table header built from these figures.
trip_revenue_to_clean_rentals AS (
  SELECT
    *,
    GREATEST(0, duration_minutes - free_window_minutes) AS overage_minutes,
    CEIL(GREATEST(0, duration_minutes - free_window_minutes) / 30) AS overage_30min_blocks,
    ROUND(
      base_unlock_fee + (CEIL(GREATEST(0, duration_minutes - free_window_minutes) / 30) * overage_rate_per_30_min),
    2) AS estimated_trip_revenue
  FROM priced_trips_base
)

-- Standalone sanity check for Part B on its own: inspect the cleaned,
-- priced trip-level table before moving on to Parts C-F below.
SELECT *
FROM trip_revenue_to_clean_rentals
LIMIT 100;


/* ============================================================================
   PART C — TIME & SEASONALITY
   ============================================================================ */

-- C.1 — Daily ride volume over the whole study window. This is what first
-- exposed the "semester break effect": a hard ramp-up in rides in mid/late
-- January that lines up with the university's spring semester start,
-- consistent with students being the largest subscriber group (Table 3).
-- Needs: cleaned_rentals (Part B.1) only — the revenue/membership CTEs
-- aren't required for this one.
--
--   SELECT
--     DATE(start_time) AS day_date,
--     day_name,
--     COUNT(trip_id) AS number_of_rides
--   FROM cleaned_rentals
--   GROUP BY day_date, day_name
--   ORDER BY day_date;


-- C.2 — Rides by month, per station, split into departures vs arrivals.
-- This is how the two "silently missing" stations were caught: station
-- 28th/Rio Grande (ID 3793) has zero rides of any kind in March, and
-- 22nd/Pearl (ID 3792) has zero *starting* rides in January — neither
-- shows up as an error, they just look like unusually quiet stations
-- unless you check month-by-month.
-- Needs: cleaned_rentals (Part B.1) only.
month_by_end_station AS (
  SELECT
    SUM(CASE WHEN EXTRACT(MONTH FROM start_time) = 1 THEN 1 ELSE 0 END) AS rides_jan_end,
    SUM(CASE WHEN EXTRACT(MONTH FROM start_time) = 2 THEN 1 ELSE 0 END) AS rides_feb_end,
    SUM(CASE WHEN EXTRACT(MONTH FROM start_time) = 3 THEN 1 ELSE 0 END) AS rides_march_end,
    end_id_fixed,
    end_station_name AS station
  FROM cleaned_rentals
  GROUP BY end_id_fixed, end_station_name
),
month_by_start_station AS (
  SELECT
    SUM(CASE WHEN EXTRACT(MONTH FROM start_time) = 1 THEN 1 ELSE 0 END) AS rides_jan_start,
    SUM(CASE WHEN EXTRACT(MONTH FROM start_time) = 2 THEN 1 ELSE 0 END) AS rides_feb_start,
    SUM(CASE WHEN EXTRACT(MONTH FROM start_time) = 3 THEN 1 ELSE 0 END) AS rides_march_start,
    start_id_fixed
  FROM cleaned_rentals
  GROUP BY start_id_fixed
)
SELECT
  e.station,
  e.rides_jan_end, e.rides_feb_end, e.rides_march_end,
  s.rides_jan_start, s.rides_feb_start, s.rides_march_start
FROM month_by_end_station e
LEFT JOIN month_by_start_station s ON s.start_id_fixed = e.end_id_fixed
ORDER BY s.rides_feb_start DESC;


/* ============================================================================
   PART D — FLEET UTILIZATION
   D.1 and D.2 run directly against the raw rentals table (not the Part B
   cleaning chain) since they only need bike_id/bike_type/duration — no
   revenue or membership fields involved. D.1 applies its own light
   duration filter (3–480 minutes) to exclude data-entry extremes; D.2
   intentionally applies no filter, since it's counting total lifetime
   rides per physical bike regardless of any one trip's length. D.3 is a
   continuation of Part B instead, since it needs the ID-consolidated
   station IDs in cleaned_rentals to correctly identify each bike's last
   known station.
   ============================================================================ */

-- D.1 — Per-bike usage vs. the fleet (and vs. its own bike-type average),
-- using window functions so every bike keeps its own row while also
-- carrying fleet-wide and type-wide benchmarks for comparison. Built to
-- flag both barely-used bikes and, for electric bikes specifically,
-- candidates for battery-wear inspection (very high ride counts vs. type
-- average).
WITH bike_counts AS (
  SELECT
    bike_id,
    bike_type,
    COUNT(*) AS total_rides_per_bike,
    AVG(duration_minutes) AS average_ride_duration
  FROM `bqproj-488319.zen_city.rentals`
  WHERE bike_id IS NOT NULL
    AND duration_minutes < (8 * 60)
    AND duration_minutes > 3
  GROUP BY bike_id, bike_type
)
SELECT
  bike_id,
  bike_type,
  total_rides_per_bike,
  average_ride_duration,
  MAX(total_rides_per_bike) OVER () AS max_rides_in_fleet,
  AVG(total_rides_per_bike) OVER () AS avg_rides_per_bike,
  total_rides_per_bike - AVG(total_rides_per_bike) OVER () AS distance_from_fleet_avg,
  AVG(total_rides_per_bike) OVER (PARTITION BY bike_type) AS avg_rides_for_this_type,
  total_rides_per_bike - AVG(total_rides_per_bike) OVER (PARTITION BY bike_type) AS distance_from_type_avg
FROM bike_counts
ORDER BY total_rides_per_bike DESC;


-- D.2 — Rolls every bike up into 5 usage tiers (source query for the
-- "Fleet Utilization Crisis" chart), split by bike type via COUNTIF. This
-- is what showed 25% of the fleet sits in the bottom "1-4 rides"
-- under-utilized tier, and that tier is almost entirely classic bikes.
WITH bike_metrics AS (
  SELECT
    bike_id,
    bike_type,
    COUNT(*) AS rides_per_bike
  FROM `bqproj-488319.zen_city.rentals`
  WHERE bike_id IS NOT NULL
  GROUP BY bike_id, bike_type
),
bucketed_data AS (
  SELECT
    bike_type,
    CASE
      WHEN rides_per_bike <= 4 THEN '1: 1-4 Rides (Under-utilized)'
      WHEN rides_per_bike <= 15 THEN '2: 5-15 Rides (Light Activity)'
      WHEN rides_per_bike <= 35 THEN '3: 16-35 Rides (Moderate)'
      WHEN rides_per_bike <= 60 THEN '4: 36-60 Rides (High Activity)'
      ELSE '5: 61+ Rides (Heavy Duty)'
    END AS usage_tier
  FROM bike_metrics
)
SELECT
  usage_tier,
  COUNTIF(bike_type = 'classic') AS classic_bikes_count,
  COUNTIF(bike_type = 'electric') AS electric_bikes_count,
  COUNT(*) AS total_bikes_in_tier
FROM bucketed_data
GROUP BY usage_tier
ORDER BY usage_tier;


-- D.3 — Placement vs. demand: where did under-utilized bikes actually end
-- up, and how busy is that station?
-- D.2 shows 25% of the fleet generating under 5 rides, almost all classic
-- — but that alone can't tell us whether classic bikes are genuinely less
-- wanted, or simply sitting at low-traffic stations where no bike would
-- get much use. This compares each bike's own usage tier against the
-- traffic level of the station where it was last seen, to separate the
-- two explanations. Needs: cleaned_rentals (Part B.1).
--
-- Result: classic and electric bikes are parked across the four
-- station-traffic quartiles in almost identical proportions (~51% of each
-- type were last seen at the busiest quartile of stations, ~9%/~7% at the
-- quietest) — so classic bikes are not disproportionately stuck at quiet
-- stations. Yet 73% of under-utilized classic bikes (96 of 131) are last
-- seen at the two busiest quartiles. Classic bikes get little use even
-- where station traffic is highest, which rules out placement as the
-- explanation and points to a genuine rider preference for electric bikes.

bike_last_location AS (
  -- Each bike's most recent trip in the dataset: where it was dropped
  -- off, and when. This is the best available proxy for "where does this
  -- bike currently sit."
  SELECT
    bike_id,
    bike_type,
    end_id_fixed AS last_known_station_id,
    end_station_name AS last_known_station_name,
    end_time AS last_seen_time,
    ROW_NUMBER() OVER (PARTITION BY bike_id ORDER BY end_time DESC) AS rn
  FROM cleaned_rentals
  WHERE bike_id IS NOT NULL
),
bike_last_location_dedup AS (
  SELECT bike_id, bike_type, last_known_station_id, last_known_station_name, last_seen_time
  FROM bike_last_location
  WHERE rn = 1
),
bike_usage AS (
  -- Same usage-tier logic as D.2, kept in sync with that chart.
  SELECT
    bike_id,
    bike_type,
    COUNT(*) AS total_rides_per_bike
  FROM cleaned_rentals
  WHERE bike_id IS NOT NULL
  GROUP BY bike_id, bike_type
),
station_traffic AS (
  -- Total trip-touches (as a start OR end station) per station, purely to
  -- rank stations by how busy they are for this comparison.
  SELECT
    station_id,
    SUM(touches) AS total_station_touches
  FROM (
    SELECT start_id_fixed AS station_id, COUNT(*) AS touches FROM cleaned_rentals GROUP BY start_id_fixed
    UNION ALL
    SELECT end_id_fixed AS station_id, COUNT(*) AS touches FROM cleaned_rentals GROUP BY end_id_fixed
  )
  GROUP BY station_id
),
station_traffic_tier AS (
  -- Split stations into four traffic quartiles: Q1 = quietest, Q4 = busiest.
  SELECT
    station_id,
    total_station_touches,
    NTILE(4) OVER (ORDER BY total_station_touches) AS traffic_quartile
  FROM station_traffic
)
SELECT
  u.bike_type,
  CASE
    WHEN u.total_rides_per_bike <= 4 THEN '1: 1-4 Rides (Under-utilized)'
    WHEN u.total_rides_per_bike <= 15 THEN '2: 5-15 Rides (Light Activity)'
    WHEN u.total_rides_per_bike <= 35 THEN '3: 16-35 Rides (Moderate)'
    WHEN u.total_rides_per_bike <= 60 THEN '4: 36-60 Rides (High Activity)'
    ELSE '5: 61+ Rides (Heavy Duty)'
  END AS usage_tier,
  CASE t.traffic_quartile
    WHEN 1 THEN 'Q1: Lowest-traffic stations'
    WHEN 2 THEN 'Q2'
    WHEN 3 THEN 'Q3'
    WHEN 4 THEN 'Q4: Highest-traffic stations'
  END AS last_parked_station_traffic,
  COUNT(*) AS number_of_bikes,
  MIN(l.last_seen_time) AS earliest_last_seen,
  MAX(l.last_seen_time) AS latest_last_seen
FROM bike_usage u
JOIN bike_last_location_dedup l ON u.bike_id = l.bike_id
JOIN station_traffic_tier t ON l.last_known_station_id = t.station_id
GROUP BY u.bike_type, usage_tier, last_parked_station_traffic
ORDER BY u.bike_type, usage_tier, last_parked_station_traffic;


/* ============================================================================
   PART E — STATION OPERATIONS
   Both queries below are continuations of Part B (see the file header for
   how to paste them together). E.1 needs cleaned_rentals + cleaned_station_info;
   E.2 needs trip_revenue_to_clean_rentals + cleaned_station_info + cleaned_rentals.
   ============================================================================ */

-- E.1 — Net-flow / rebalancing risk model.
-- Business question: which stations create the most operational pressure
-- by chronically emptying out (bike shortage) or filling up (dock
-- gridlock)? Rebalancing bikes between stations is a real labor cost, so
-- this identifies exactly where and when it's most needed.
--
-- Method, step by step:
--   1. Data densification — build a master hour-by-hour calendar grid per
--      station (bounded to each station's own active lifespan) so an hour
--      with zero rides is recorded as a true zero, not a missing row that
--      would silently inflate the remaining hours' averages.
--   2. Anomaly quarantine — drop entire calendar days where system-wide
--      rides fell below 60 (severe winter storms, the March tracking
--      outage), so those one-off shocks don't distort the "typical" hourly
--      pattern being modeled.
--   3. Historical hourly averages — for each station/day-of-week/hour,
--      average net flow (arrivals minus departures) across all valid days,
--      plus its standard error.
--   4. Cumulative net flow — running sum of hourly net flow across the day,
--      to see when a station's balance is projected to cross zero.
--   5. 95% confidence interval — hourly standard errors are propagated
--      (root sum of squares) up to the cumulative total, so the risk flag
--      reflects uncertainty, not just a single noisy average.
-- Scope: restricted to February-March (Jan excluded, since Winter Break
-- ridership follows a different pattern entirely — see Part C).
-- Limitation: this dataset has no record of the company's own rebalancing
-- activity (staff/trucks physically moving bikes between stations), so the
-- model measures relative demand pressure — how far a station's balance
-- would drift if nothing intervened — not a validated, absolute "ran out
-- of bikes/docks" event, since real intervention during the day isn't
-- visible here.

raw_activity_timeline AS (
  SELECT start_id_fixed AS station_id, start_station_name AS station_name, start_time AS trip_time, 1 AS is_departure, 0 AS is_arrival FROM cleaned_rentals
  UNION ALL
  SELECT end_id_fixed AS station_id, end_station_name AS station_name, end_time AS trip_time, 0 AS is_departure, 1 AS is_arrival FROM cleaned_rentals
),
station_lifespan AS (
  SELECT station_id, station_name, MIN(trip_time) AS first_seen, MAX(trip_time) AS last_seen
  FROM raw_activity_timeline
  WHERE station_id IS NOT NULL
  GROUP BY 1, 2
),
-- Anomaly filter: map total system rides against a full calendar (catches
-- zero-ride days), then only keep days where the network had >= 60 rides.
system_daily_volume AS (
  SELECT
    cal_date,
    COALESCE(SUM(r.is_departure), 0) AS system_total_rides
  FROM UNNEST(GENERATE_DATE_ARRAY('2022-02-01', '2022-03-31')) AS cal_date
  LEFT JOIN raw_activity_timeline r ON cal_date = DATE(r.trip_time)
  GROUP BY 1
),
valid_operational_days AS (
  SELECT cal_date
  FROM system_daily_volume
  WHERE system_total_rides >= 60   -- drops the storm/outage days (e.g. 0, 51, 6 total rides)
),
master_time_grid AS (
  SELECT
    s.station_id,
    s.station_name,
    base_time,
    DATE(base_time) AS trip_date,
    EXTRACT(HOUR FROM base_time) AS hour_of_day,
    FORMAT_TIMESTAMP('%A', base_time) AS day_name,
    EXTRACT(DAYOFWEEK FROM base_time) AS day_num
  FROM station_lifespan s
  CROSS JOIN UNNEST(
    GENERATE_TIMESTAMP_ARRAY('2022-02-01 00:00:00', '2022-03-31 23:00:00', INTERVAL 1 HOUR)
  ) AS base_time
  -- Only keep hours on days that survived the anomaly filter above.
  INNER JOIN valid_operational_days v ON DATE(base_time) = v.cal_date
  -- Only keep hours within this specific station's own active window, so a
  -- station that opened or closed mid-period isn't penalized with
  -- artificial zeroes outside its real lifespan.
  WHERE base_time >= TIMESTAMP_TRUNC(s.first_seen, HOUR)
    AND base_time <= TIMESTAMP_TRUNC(s.last_seen, HOUR)
),
hourly_raw_counts AS (
  SELECT
    station_id,
    TIMESTAMP_TRUNC(trip_time, HOUR) AS hour_timestamp,
    SUM(is_arrival) AS arrivals,
    SUM(is_departure) AS departures
  FROM raw_activity_timeline
  GROUP BY 1, 2
),
daily_hourly_totals AS (
  SELECT
    g.station_name,
    g.station_id,
    g.trip_date,
    g.hour_of_day,
    g.day_name,
    g.day_num,
    COALESCE(r.arrivals, 0) AS arrivals,
    COALESCE(r.departures, 0) AS departures,
    COALESCE(r.arrivals, 0) - COALESCE(r.departures, 0) AS hourly_net_flow
  FROM master_time_grid g
  LEFT JOIN hourly_raw_counts r
    ON g.station_id = r.station_id AND g.base_time = r.hour_timestamp
),
average_profiles AS (
  SELECT
    station_name,
    station_id,
    day_num,
    day_name,
    hour_of_day,
    AVG(departures) AS avg_depart,
    AVG(arrivals) AS avg_arrivals,
    AVG(hourly_net_flow) AS avg_hourly_net_flow,
    ROUND(SAFE_DIVIDE(STDDEV(hourly_net_flow), SQRT(COUNT(*))), 2) AS se_net_flow,
    COUNT(*) AS valid_days_averaged
  FROM daily_hourly_totals
  GROUP BY 1, 2, 3, 4, 5
),
cumulative_metrics AS (
  SELECT
    p.station_id,
    p.day_num,
    p.hour_of_day,
    s.number_of_docks,
    s.name,
    SUM(p.avg_depart) OVER (PARTITION BY p.station_id, p.day_num ORDER BY p.hour_of_day ASC) AS cumulative_avg_departures,
    SUM(p.avg_arrivals) OVER (PARTITION BY p.station_id, p.day_num ORDER BY p.hour_of_day ASC) AS cumulative_avg_arrivals,
    SUM(p.avg_hourly_net_flow) OVER (PARTITION BY p.station_id, p.day_num ORDER BY p.hour_of_day ASC) AS expected_cumulative_balance,
    SQRT(SUM(POWER(p.se_net_flow, 2)) OVER (PARTITION BY p.station_id, p.day_num ORDER BY p.hour_of_day ASC)) AS cumulative_se
  FROM average_profiles p
  JOIN cleaned_station_info s ON p.station_id = s.station_id
),
calculated_bounds AS (
  SELECT
    station_id,
    name,
    day_num,
    hour_of_day,
    number_of_docks,
    ROUND(cumulative_avg_arrivals, 2) AS cumulative_avg_arrivals,
    ROUND(cumulative_avg_departures, 2) AS cumulative_avg_departures,
    expected_cumulative_balance AS avg_cumulative_net_flow,
    expected_cumulative_balance - (1.96 * cumulative_se) AS lower_bound,
    expected_cumulative_balance + (1.96 * cumulative_se) AS upper_bound
  FROM cumulative_metrics
),
final_with_breach AS (
  SELECT
    station_id,
    name,
    day_num,
    hour_of_day,
    number_of_docks,
    cumulative_avg_arrivals,
    cumulative_avg_departures,
    ROUND(avg_cumulative_net_flow, 2) AS avg_cumulative_flow,
    ROUND(lower_bound, 2) AS lower_bound,
    ROUND(upper_bound, 2) AS upper_bound,

    -- Early-warning flag: triggers the moment EITHER bound of the 95% CI
    -- crosses a physical capacity wall (all bikes gone, or no docks left).
    CASE
      WHEN lower_bound <= -1 * number_of_docks THEN 'High Risk: Bike Shortage'
      WHEN upper_bound >= number_of_docks THEN 'High Risk: Dock Gridlock'
      ELSE 'Balanced'
    END AS demand_risk_profile,

    -- Stricter flag: only TRUE once BOTH bounds (i.e. even the best case)
    -- have crossed the wall — a much higher-confidence "this is really
    -- happening", useful for prioritizing which stations to act on first.
    CASE
      WHEN upper_bound <= -1 * number_of_docks THEN TRUE
      WHEN lower_bound >= number_of_docks THEN TRUE
      ELSE FALSE
    END AS capacity_guaranteed_breach
  FROM calculated_bounds
  ORDER BY station_id, day_num, hour_of_day
)
SELECT * FROM final_with_breach;


-- E.2 — Station meta-profile table: one row per station combining revenue,
-- membership mix, usage-pattern classification, and operational-imbalance
-- warnings. This is the single table the station-profiling and revenue
-- charts are built from.
--
-- Classification logic:
--   - weekend_ratio >= 0.35                                -> Casual / Recreational
--   - rush-hour trips > midday trips AND weekend_ratio<0.20 -> Pure Commuter
--   - otherwise                                             -> Hybrid / Mixed Use

combined_traffic AS (
  -- Every trip contributes one departure-side row (from its start station)
  -- and one arrival-side row (from its end station), so every station's
  -- traffic reflects both ends of the trips that touch it.
  SELECT start_id_fixed AS station_id, membership_group, customer_id, day_type, hour_of_day, estimated_trip_revenue
  FROM trip_revenue_to_clean_rentals
  UNION ALL
  SELECT end_id_fixed AS station_id, membership_group, customer_id, day_type, EXTRACT(HOUR FROM end_time) AS hour_of_day, estimated_trip_revenue
  FROM trip_revenue_to_clean_rentals
),
station_behavior AS (
  SELECT
    station_id,
    -- Every trip appears twice in combined_traffic (once as a departure
    -- row, once as an arrival row) — every COUNT/SUM below is divided by 2
    -- to get back to real trip-level counts and revenue.
    SUM(estimated_trip_revenue) / 2 AS estimated_total_revenue_per_station,
    COUNTIF(day_type = 'Weekday' AND hour_of_day IN (7, 8, 9, 16, 17, 18)) / 2 AS rush_hour_trips,
    COUNTIF(hour_of_day IN (11, 12, 13, 14, 15)) / 2 AS midday_trips,
    COUNTIF(day_type = 'Weekend') / 2 AS weekend_trips,
    COUNT(*) / 2 AS total_trips,
    COUNTIF(day_type = 'Weekday') / 2 AS weekday_trips,
    COUNT(DISTINCT customer_id) AS total_station_users,
    COUNTIF(membership_group = 'Student') / 2 AS student_plan_trips,
    COUNTIF(membership_group = 'Single Trip') / 2 AS single_trip_count,
    COUNTIF(membership_group = 'Short-Term') / 2 AS short_term_count,
    COUNTIF(membership_group = 'Monthly') / 2 AS monthly_count_trips,
    COUNTIF(membership_group = 'Annual') / 2 AS annual_trip_count,
    SUM(CASE WHEN membership_group = 'Student' THEN estimated_trip_revenue END) / 2 AS estimated_student_revenue,
    SUM(CASE WHEN membership_group = 'Single Trip' THEN estimated_trip_revenue END) / 2 AS estimated_single_trip_revenue,
    SUM(CASE WHEN membership_group = 'Short-Term' THEN estimated_trip_revenue END) / 2 AS estimated_short_term_revenue,
    SUM(CASE WHEN membership_group = 'Monthly' THEN estimated_trip_revenue END) / 2 AS estimated_monthly_revenue,
    SUM(CASE WHEN membership_group = 'Annual' THEN estimated_trip_revenue END) / 2 AS estimated_annual_revenue
  FROM combined_traffic
  GROUP BY station_id
),
meta_data_stations AS (
  SELECT
    b.station_id,
    s.status,
    s.clean_name AS station_name,
    b.estimated_total_revenue_per_station,
    b.total_trips,
    b.weekday_trips,
    b.weekend_trips,
    ROUND(b.weekend_trips / b.total_trips, 2) AS weekend_ratio,
    b.total_station_users,
    b.student_plan_trips,
    b.single_trip_count,
    b.short_term_count,
    b.monthly_count_trips,
    b.annual_trip_count,
    b.estimated_student_revenue,
    b.estimated_single_trip_revenue,
    b.estimated_short_term_revenue,
    b.estimated_monthly_revenue,
    b.estimated_annual_revenue,
    CASE
      WHEN (b.weekend_trips / b.total_trips) >= 0.35 THEN 'Casual / Recreational'
      WHEN b.rush_hour_trips > b.midday_trips AND (b.weekend_trips / b.total_trips) < 0.20 THEN 'Pure Commuter'
      ELSE 'Hybrid / Mixed Use'
    END AS station_profile,
    CASE
      WHEN b.station_id IN (SELECT DISTINCT start_id_fixed FROM cleaned_rentals) THEN 'also start station'
      ELSE 'not a starting station'
    END AS also_in_start
  FROM station_behavior b
  LEFT JOIN cleaned_station_info s ON b.station_id = s.station_id
),

-- The block below re-derives net flow, scoped to February-March, purely to
-- drive the per-station imbalance warning array further down.
daily_hourly_totals AS (
  SELECT
    station_name,
    station_id,
    DATE(start_time) AS trip_date,
    EXTRACT(HOUR FROM start_time) AS hour_of_day,
    FORMAT_DATETIME('%A', start_time) AS day_name,
    EXTRACT(DAYOFWEEK FROM start_time) AS day_num,
    SUM(is_arrival) - SUM(is_departure) AS daily_net_flow,
    SUM(is_arrival) AS arrivals,
    SUM(is_departure) AS departures
  FROM (
    SELECT start_station_name AS station_name, start_id_fixed AS station_id, start_time, 1 AS is_departure, 0 AS is_arrival
    FROM cleaned_rentals
    WHERE DATE(start_time) BETWEEN '2022-02-01' AND '2022-03-31'
    UNION ALL
    SELECT end_station_name AS station_name, end_id_fixed AS station_id, end_time, 0 AS is_departure, 1 AS is_arrival
    FROM cleaned_rentals
    WHERE DATE(end_time) BETWEEN '2022-02-01' AND '2022-03-31'
  )
  GROUP BY 1, 2, 3, 4, 5, 6
),
average_profiles AS (
  SELECT
    station_name, station_id, day_num, day_name, hour_of_day,
    AVG(departures) AS avg_depart,
    AVG(arrivals) AS avg_arrivals,
    AVG(daily_net_flow) AS avg_hourly_net_flow,
    ROUND(STDDEV(daily_net_flow) / SQRT(COUNT(*)), 2) AS standard_error_of_net_flow,
    COUNT(*) AS days_averaged
  FROM daily_hourly_totals
  GROUP BY 1, 2, 3, 4, 5
),
cumulative_profiles AS (
  SELECT
    p.*,
    -- Rolling balance across the day, starting at midnight.
    ROUND(SUM(p.avg_hourly_net_flow) OVER (PARTITION BY p.station_id, p.day_num ORDER BY p.hour_of_day ASC), 2) AS cumulative_net_imbalance
  FROM average_profiles p
),
average_flow AS (
  SELECT
    p.station_id,
    s.clean_name AS name,
    s.number_of_docks,
    p.day_name,
    p.day_num,
    p.hour_of_day,
    p.days_averaged,
    ROUND(p.avg_hourly_net_flow, 2) AS avg_net_flow,
    p.cumulative_net_imbalance,
    -- Tests the cumulative imbalance against 75% of the station's physical
    -- dock capacity, on either side.
    CASE
      WHEN p.cumulative_net_imbalance <= -(s.number_of_docks * 0.75) THEN 'Critical: Depleted Station'
      WHEN p.cumulative_net_imbalance >= (s.number_of_docks * 0.75) THEN 'Critical: Full Station Jam'
      ELSE 'Stable Flow'
    END AS dynamic_inventory_status,
    p.avg_depart,
    p.avg_arrivals,
    p.standard_error_of_net_flow
  FROM cumulative_profiles p
  LEFT JOIN cleaned_station_info s ON p.station_id = s.station_id
),
meta_station_warnings AS (
  SELECT
    station_id,
    name,
    number_of_docks,
    -- All distinct alert types a station triggered across the whole month.
    ARRAY_AGG(DISTINCT dynamic_inventory_status ORDER BY dynamic_inventory_status) AS triggered_alerts,
    -- The specific days of the week a problem actually occurred (useful
    -- for targeting rebalancing staff to specific days, not just stations).
    ARRAY_AGG(DISTINCT CASE WHEN dynamic_inventory_status != 'Stable Flow' THEN day_name END IGNORE NULLS) AS problematic_days,
    MIN(cumulative_net_imbalance) AS max_bike_deficit,
    MAX(cumulative_net_imbalance) AS max_bike_surplus
  FROM average_flow
  GROUP BY 1, 2, 3
),
final_aggregated_warnings AS (
  SELECT
    station_id,
    name,
    number_of_docks,
    -- Collapse "Stable Flow" out of the alert list entirely once any real
    -- problem exists; if it's the *only* thing that ever triggered, relabel
    -- it plainly as a stable station.
    CASE
      WHEN ARRAY_LENGTH(triggered_alerts) = 1 AND triggered_alerts[OFFSET(0)] = 'Stable Flow' THEN ['Stable Station']
      ELSE ARRAY(SELECT alert FROM UNNEST(triggered_alerts) AS alert WHERE alert != 'Stable Flow')
    END AS operational_warnings,
    CASE WHEN ARRAY_LENGTH(problematic_days) = 0 THEN ['All Days Stable'] ELSE problematic_days END AS problematic_days,
    max_bike_deficit,
    max_bike_surplus
  FROM meta_station_warnings
)
SELECT
  mdt.*,
  w.operational_warnings,
  w.number_of_docks
FROM meta_data_stations mdt
LEFT JOIN final_aggregated_warnings w ON mdt.station_id = w.station_id
ORDER BY mdt.estimated_total_revenue_per_station DESC;


/* ============================================================================
   PART F — CUSTOMERS & REVENUE
   F.1 and F.2 are continuations of Part B. F.1 needs
   trip_revenue_to_clean_rentals; F.2 needs trip_revenue_to_clean_rentals
   plus the `customers` table. F.3 is independent — it only needs
   cleaned_rentals (Part B.1) and can be run as its own standalone query.
   ============================================================================ */

-- F.1 — Membership history: for every customer, roll up lifetime rides and
-- revenue per membership group they've ever used, then take their most
-- recently used group as their "current" plan. Used to size the steady,
-- recurring revenue base (this is how the 483 students / 28 annual
-- members figures were derived) rather than to build clean behavioral
-- segments — a look at individual histories showed some customers
-- switching between all 5 membership groups within days of each other,
-- which is far more plan-switching than real behavior would produce.
-- customer_id is a synthetic add-on to the underlying public Austin
-- B-cycle dataset (it has no real customer-level tracking), and appears
-- to have been assigned per ride without regard to that ride's own
-- subscriber_type — which is the most likely source of this pattern.
membership_summary AS (
  SELECT
    customer_id,
    membership_group,
    COUNT(*) AS rides_under_this_group,
    SUM(estimated_trip_revenue) AS estimated_total_trips_revenue,
    MAX(start_time) AS latest_date_for_group
  FROM trip_revenue_to_clean_rentals
  GROUP BY customer_id, membership_group
),
ranked_history AS (
  SELECT
    *,
    SUM(rides_under_this_group) OVER (PARTITION BY customer_id) AS total_lifetime_rides,
    COUNT(membership_group) OVER (PARTITION BY customer_id) AS total_groups_tried,
    ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY latest_date_for_group DESC) AS recency_rank
  FROM membership_summary
),
last_updated_membership_group AS (
  SELECT
    customer_id,
    membership_group AS current_membership_category,
    total_lifetime_rides,
    estimated_total_trips_revenue,
    total_groups_tried,
    latest_date_for_group AS last_active_date
  FROM ranked_history
  WHERE recency_rank = 1
)
SELECT
  current_membership_category,
  COUNT(*) AS current_group_number_of_members,
  SUM(total_lifetime_rides) AS total_rides_per_group
FROM last_updated_membership_group
GROUP BY current_membership_category
ORDER BY total_rides_per_group DESC;


-- F.2 — Demographic segmentation: total rides, total revenue, and average
-- ride duration by age group x gender. This is the source query for the
-- rider-demographics chart (young professional women, and high-value
-- senior riders).
revenue_customer_table AS (
  SELECT
    r.customer_id,
    c.age,
    c.gender,
    r.estimated_trip_revenue,
    r.trip_id,
    r.duration_minutes
  FROM trip_revenue_to_clean_rentals r
  LEFT JOIN `bqproj-488319.zen_city.customers` c ON r.customer_id = c.customer_id
),
customer_demographics AS (
  SELECT
    customer_id,
    trip_id,
    duration_minutes,
    estimated_trip_revenue,
    CASE
      WHEN age BETWEEN 18 AND 24 THEN '18-24: (Gen Z)'
      WHEN age BETWEEN 25 AND 34 THEN '25-34: (Young Prof)'
      WHEN age BETWEEN 35 AND 44 THEN '35-44: (Adults)'
      WHEN age BETWEEN 45 AND 54 THEN '45-54: (Middle Age)'
      WHEN age >= 55 THEN '55+: (Seniors)'
      ELSE 'Unknown / Other'
    END AS age_group,
    gender
  FROM revenue_customer_table
)
SELECT
  age_group,
  gender,
  COUNT(trip_id) AS total_rides,
  SUM(estimated_trip_revenue) AS estimated_total_revenue,
  ROUND(AVG(duration_minutes), 2) AS average_ride_duration
FROM customer_demographics
GROUP BY age_group, gender
ORDER BY age_group ASC, gender DESC;


-- F.3 — Monthly-membership base, by month: how many distinct customers held
-- an active Monthly plan in each calendar month of Q1. A Monthly rider pays
-- their pass fee whether they ride once that month or thirty times, and
-- Part B.6's per-trip model deliberately does NOT include that fee (Monthly
-- trips pay a $0 unlock fee there — see priced_trips_base) — it only bills
-- overage minutes past the free window. This query exists to fill that gap:
-- multiply active_monthly_customers by the actual monthly pass price (not
-- captured anywhere in this dataset) to get the prepaid subscription revenue
-- for that month, then add it to estimated_monthly_revenue from Part B/C/D
-- for a true total rather than a per-trip-only figure.
-- Definition used here: a customer counts as an active Monthly member in a
-- given month if they took at least one Monthly-categorized ride that
-- month — there's no separate membership/billing table in this dataset, so
-- a customer who paid for a Monthly pass but never rode in a given month
-- would be missed. That makes this a floor on the true active-member count,
-- not an exact one.
-- Needs: cleaned_rentals (Part B.1) only.
monthly_membership_base AS (
  SELECT
    DATE_TRUNC(DATE(start_time), MONTH) AS membership_month,
    customer_id
  FROM cleaned_rentals
  WHERE membership_group = 'Monthly'
  GROUP BY membership_month, customer_id
)
SELECT
  membership_month,
  COUNT(DISTINCT customer_id) AS active_monthly_customers
FROM monthly_membership_base
GROUP BY membership_month
ORDER BY membership_month;
