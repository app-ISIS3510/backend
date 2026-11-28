-- BQ16: Distance filter usage analytics.
-- Supports the last 7, 14, and 30 days.

CREATE OR REPLACE VIEW public.bq16_distance_filter_usage_last_7_days AS
SELECT
    CASE metadata ->> 'radius_meters'
        WHEN '500' THEN '500 m'
        WHEN '1000' THEN '1 km'
        WHEN '2000' THEN '2 km'
    END AS distance_filter,
    COUNT(*) AS total_searches,
    ROUND(
        COUNT(*)::numeric * 100.0 /
        SUM(COUNT(*)) OVER (),
        2
    ) AS percentage
FROM public.analytics_events
WHERE event_type = 'parking_search_performed'
    AND created_at >= NOW() - INTERVAL '7 days'
    AND metadata ->> 'search_method' = 'distance_filter'
    AND metadata ->> 'radius_meters' IN ('500', '1000', '2000')
GROUP BY metadata ->> 'radius_meters';


-- Interactive dashboard with multiple time periods.

CREATE OR REPLACE VIEW public.bq16_distance_filter_usage AS
WITH periods AS (
    SELECT 7 AS period_days
    UNION ALL
    SELECT 14
    UNION ALL
    SELECT 30
),
searches AS (
    SELECT
        p.period_days,
        CASE a.metadata ->> 'radius_meters'
            WHEN '500' THEN '500 m'
            WHEN '1000' THEN '1 km'
            WHEN '2000' THEN '2 km'
        END AS distance_filter,
        COUNT(*) AS total_searches
    FROM periods p
    JOIN public.analytics_events a
        ON a.created_at >= NOW()
            - p.period_days * INTERVAL '1 day'
    WHERE a.event_type = 'parking_search_performed'
        AND a.metadata ->> 'search_method' = 'distance_filter'
        AND a.metadata ->> 'radius_meters'
            IN ('500', '1000', '2000')
    GROUP BY
        p.period_days,
        a.metadata ->> 'radius_meters'
)
SELECT
    period_days,
    'Last ' || period_days || ' days' AS time_period,
    distance_filter,
    total_searches,
    ROUND(
        total_searches::numeric * 100.0 /
        SUM(total_searches) OVER (
            PARTITION BY period_days
        ),
        2
    ) AS percentage
FROM searches;


-- Restrict public API access to analytics views.

REVOKE ALL ON
    public.bq16_distance_filter_usage_last_7_days,
    public.bq16_distance_filter_usage
FROM PUBLIC, anon, authenticated;


-- Grant read-only access to the shared BI reader.

DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM pg_roles
        WHERE rolname = 'parku_bi_reader'
    ) THEN
        GRANT SELECT ON
            public.bq16_distance_filter_usage_last_7_days,
            public.bq16_distance_filter_usage
        TO parku_bi_reader;
    END IF;
END
$$;