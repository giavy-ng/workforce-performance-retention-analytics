INSTALL excel;
LOAD excel;

-- 0. SOURCE INGESTION
-- Load Excel sheets into temporary src_* tables for downstream profiling
CREATE OR REPLACE TEMP TABLE src_employees           AS SELECT * FROM read_xlsx('data/data_raw.xlsx', sheet = 'employees');
CREATE OR REPLACE TEMP TABLE src_stores              AS SELECT * FROM read_xlsx('data/data_raw.xlsx', sheet = 'stores');
CREATE OR REPLACE TEMP TABLE src_monthly_performance AS SELECT * FROM read_xlsx('data/data_raw.xlsx', sheet = 'monthly_performance');
CREATE OR REPLACE TEMP TABLE src_role_kpis           AS SELECT * FROM read_xlsx('data/data_raw.xlsx', sheet = 'role_kpis');
CREATE OR REPLACE TEMP TABLE src_business_outcomes   AS SELECT * FROM read_xlsx('data/data_raw.xlsx', sheet = 'business_outcomes');

/* 1. DATA PROFILING */

/* 1.1 STRUCTURAL PROFILE
   Data types, ranges, distributions, and approximate cardinality */
SELECT 'employees'           AS table_name, * FROM (SUMMARIZE src_employees); 
SELECT 'stores'              AS table_mame, * FROM (SUMMARIZE src_stores);
SELECT 'monthly_performance' AS table_name, * FROM (SUMMARIZE src_monthly_performance);
SELECT 'role_kpis'           AS table_name, * FROM (SUMMARIZE src_role_kpis);
SELECT 'business_outcomes'   AS table_name, * FROM (SUMMARIZE src_business_outcomes);


/* 1.2 MISSINGNESS */
SELECT 'employees' AS table_name, 'Exit_Date' AS column_name, COUNT(*) - COUNT(Exit_Date) AS nulls, ROUND(100*(COUNT(*)-COUNT(Exit_Date))/COUNT(*), 2) AS null_pct FROM src_employees
UNION ALL SELECT     'employees', 'Manager_Id'              , COUNT(*) - COUNT(Manager_Id)        , ROUND(100*(COUNT(*)-COUNT(Manager_Id))/COUNT(*), 2)            FROM src_employees
UNION ALL SELECT     'employees', 'Manager_Status'          , COUNT(*) - COUNT(Manager_Status)    , ROUND(100*(COUNT(*)-COUNT(Manager_Status))/COUNT(*), 2)        FROM src_employees
ORDER BY null_pct DESC;
    /*  Exit_Date: 6,009 NULLs (80.12%)
        Manager_Id and Manager_Status: 5 NULLs each (0.07%) */

-- Check whether Exit_Date NULL corresponds to employees who are still active
SELECT 
    COUNT(*) AS null_exit_employees,
    COUNT(*) FILTER (WHERE Employee_Id IN     (SELECT Employee_Id FROM src_monthly_performance WHERE Year_Month = (SELECT MAX(Year_Month) FROM src_monthly_performance))) AS active_at_panel_end,
    COUNT(*) FILTER (WHERE Employee_Id NOT IN (SELECT Employee_Id FROM src_monthly_performance WHERE Year_Month = (SELECT MAX(Year_Month) FROM src_monthly_performance))) AS not_active_at_panel_end
FROM src_employees
WHERE Exit_Date IS NULL;
    /*  6,009 employees with NULL Exit_Date remain active at the end of the panel.
        Decision: keep NULL; no imputation. */

-- Check whether NULL Manager_Id represents top-level employees
SELECT 
    Job_Level,
    COUNT(*) AS employee_count
FROM src_employees
WHERE Manager_Id IS NULL
GROUP BY Job_Level;
    /* All 5 employees without a Manager_Id are Executive-level → keep NULL */


/* 1.3 CATEGORICAL VALUES & BUSINESS CONSISTENCY 
    Categorical values were reviewed from the source workbook.
    No unexpected category, casing, or spelling issue was identified
        except for the Job_Level / Manager_Status inconsistency checked below */
-- Distinct-value counts per categorical column
SELECT col, COUNT(DISTINCT val) AS n_distinct
FROM (
    SELECT           'employees.Department'     AS col, Department      AS val FROM src_employees
    UNION ALL SELECT 'employees.Job_Role'             , Job_Role               FROM src_employees
    UNION ALL SELECT 'employees.Job_Level'            , Job_Level              FROM src_employees
    UNION ALL SELECT 'employees.Employment_Type'      , Employment_Type        FROM src_employees
    UNION ALL SELECT 'employees.Education_Level'      , Education_Level        FROM src_employees
    UNION ALL SELECT 'employees.Manager_Status'       , Manager_Status         FROM src_employees
    UNION ALL SELECT 'stores.Store_Type'              , Store_Type             FROM src_stores
    UNION ALL SELECT 'business_outcomes.Department'   , Department             FROM src_business_outcomes
    UNION ALL SELECT 'role_kpis.Kpi_1_Name'           , Kpi_1_Name             FROM src_role_kpis
    UNION ALL SELECT 'role_kpis.Kpi_2_Name'           , Kpi_2_Name             FROM src_role_kpis
    UNION ALL SELECT 'role_kpis.Kpi_3_Name'           , Kpi_3_Name             FROM src_role_kpis
)
GROUP BY col;

-- Check whether Manager_Status represents the manager's actual Job_Level
SELECT
    e.Manager_Status
    , m.Job_Level AS manager_job_level
    , COUNT(*) AS n
FROM src_employees e 
JOIN src_employees m 
    ON m.Employee_Id = e.Manager_Id
GROUP BY 1, 2
ORDER BY n DESC;
    /*  Manager_Status matches the manager's Job_Level in all cases.
        Difference is formatting only: "Senior Manager" vs "Senior_Manager" */

-- Check Manager_Id -> Manager_Name consistency
SELECT 'manager_ids_with_multiple_names' AS check,
       (SELECT COUNT(*) FROM (SELECT Manager_Id FROM src_employees WHERE Manager_Id IS NOT NULL
                              GROUP BY Manager_Id HAVING COUNT(DISTINCT Manager_Name) > 1)) AS value;
    /* Each Manager_Id maps to a single Manager_Name. */


/* 1.4 GRAIN & PRIMARY KEYS */
SELECT table_name, declared_grain, rows, distinct_keys
    , CASE WHEN rows = distinct_keys THEN 'PASS' ELSE 'FAIL - duplicate keys' END AS result
FROM (
    SELECT           'employees' AS table_name, 'Employee_Id' AS declared_grain,
        COUNT(*) AS rows, COUNT(DISTINCT Employee_Id) AS distinct_keys       FROM src_employees
    UNION ALL SELECT 'stores'                 , 'Store_Id',
        COUNT(*)        , COUNT(DISTINCT Store_Id)                           FROM src_stores
    UNION ALL SELECT 'monthly_performance'    , 'Employee_Id + Year_Month',
        COUNT(*)        , COUNT(DISTINCT (Employee_Id, Year_Month))          FROM src_monthly_performance
    UNION ALL SELECT 'role_kpis'              , 'Employee_Id + Year_Month',
        COUNT(*)        , COUNT(DISTINCT (Employee_Id, Year_Month))          FROM src_role_kpis
    UNION ALL SELECT 'business_outcomes'      , 'Store_Id + Department + Year_Month',
        COUNT(*)        , COUNT(DISTINCT (Store_Id, Department, Year_Month)) FROM src_business_outcomes
);
    /* All declared grains are unique */

-- Check monthly_performance vs role_kpis key alignment
SELECT 'monthly_performance vs role_kpis key alignment' AS check,
    (SELECT COUNT(*)
    FROM(
        SELECT Employee_Id, Year_Month FROM src_monthly_performance
        EXCEPT SELECT Employee_Id, Year_Month FROM src_role_kpis
        UNION ALL
        SELECT Employee_Id, Year_Month FROM src_role_kpis
        EXCEPT SELECT Employee_Id, Year_Month FROM src_monthly_performance
        )
    ) AS symmetric_difference;
    /* Result: 0 -> identical key sets; 1:1 join is safe. */


/* 1.5 REFERENTIAL INTEGRITY 
    Check whether foreign-key relationships are valid and whether 
        unmatched parent records require further investigation */
SELECT fk, orphans,
    CASE WHEN orphans = 0 THEN 'PASS' ELSE 'FAIL' END AS result, unreferenced_parents
FROM (
    SELECT 'monthly_performance.Employee_Id -> employees' AS fk,
        (SELECT COUNT(DISTINCT Employee_Id) FROM src_monthly_performance
        WHERE Employee_Id NOT IN (SELECT Employee_Id FROM src_employees)) AS orphans,
        (SELECT COUNT(*) FROM src_employees
        WHERE Employee_Id NOT IN (SELECT Employee_Id FROM src_monthly_performance)) AS unreferenced_parents
    UNION ALL
    SELECT 'role_kpis.Employee_Id -> employees',
        (SELECT COUNT(DISTINCT Employee_Id) FROM src_role_kpis
        WHERE Employee_Id NOT IN (SELECT Employee_Id FROM src_employees)),
        (SELECT COUNT(*) FROM src_employees
        WHERE Employee_Id NOT IN (SELECT Employee_Id FROM src_role_kpis))
    UNION ALL
    SELECT 'employees.Store_Id -> stores',
        (SELECT COUNT(DISTINCT Store_Id) FROM src_employees
        WHERE Store_Id NOT IN (SELECT Store_Id FROM src_stores)),
        (SELECT COUNT(*) FROM src_stores
        WHERE Store_Id NOT IN (SELECT Store_Id FROM src_employees))
    UNION ALL
    SELECT 'business_outcomes.Store_Id -> stores',
        (SELECT COUNT(DISTINCT Store_Id) FROM src_business_outcomes
        WHERE Store_Id NOT IN (SELECT Store_Id FROM src_stores)),
        (SELECT COUNT(*) FROM src_stores
        WHERE Store_Id NOT IN (SELECT Store_Id FROM src_business_outcomes))
    UNION ALL
    SELECT 'employees.Manager_Id -> employees (self)',
        (SELECT COUNT(DISTINCT Manager_Id) FROM src_employees
        WHERE Manager_Id IS NOT NULL AND Manager_Id NOT IN (SELECT Employee_Id FROM src_employees)),
        NULL
);
    /*  All orphan checks PASS.
        414 employees in employees are not present in the performance panel. */

-- Check whether employees absent from the performance panel exited before the observation period
SELECT
    COUNT(*) AS employees_absent_from_panel
    , COUNT(*) FILTER (WHERE strptime(e.Exit_Date, '%d/%m/%Y') < panel_start)                         AS exited_from_panel_start
    , COUNT(*) FILTER (WHERE strptime(e.Exit_Date, '%d/%m/%Y') >= panel_start OR e.Exit_Date IS NULL) AS requires_review
FROM src_employees e  
CROSS JOIN (
    SELECT MIN(strptime(Year_Month || '-01', '%Y-%m-%d')) AS panel_start
    FROM src_monthly_performance
) p 
WHERE e.Employee_Id NOT IN (SELECT Employee_Id FROM src_monthly_performance);

-- Check whether NULL Manager_Id values correspond to top-level employees
SELECT
    Job_Level
    , COUNT(*) AS employees_without_manager
FROM src_employees
WHERE Manager_Id IS NULL
GROUP BY Job_Level;
    /*  All 5 employees without Manager_Id are Executives.
        NULL Manager_Id is structurally valid for the top level. */


/* 1.6 DOMAIN & RANGE VALIDATION
   Check values against business-valid ranges.
   PASS = no impossible values; no clipping or winsorisation required */
SELECT col, violations, CASE WHEN violations = 0 THEN 'PASS' ELSE 'FAIL' END AS result FROM (VALUES
    ('employees.Age [16..75]',                   (SELECT COUNT(*) FROM src_employees           WHERE Age NOT BETWEEN 16 AND 75)),
    ('employees.Base_Salary_Annual > 0',         (SELECT COUNT(*) FROM src_employees           WHERE Base_Salary_Annual <= 0)),
    ('mp.Performance_Rating [1..5]',             (SELECT COUNT(*) FROM src_monthly_performance WHERE Performance_Rating NOT BETWEEN 1 AND 5)),
    ('mp.Manager_Evaluation [1..5]',             (SELECT COUNT(*) FROM src_monthly_performance WHERE Manager_Evaluation NOT BETWEEN 1 AND 5)),
    ('mp.Employee_Satisfaction [1..10]',         (SELECT COUNT(*) FROM src_monthly_performance WHERE Employee_Satisfaction NOT BETWEEN 1 AND 10)),
    ('mp.Engagement_Index [1..10]',              (SELECT COUNT(*) FROM src_monthly_performance WHERE Engagement_Index NOT BETWEEN 1 AND 10)),
    ('mp.Training_Hours >= 0',                   (SELECT COUNT(*) FROM src_monthly_performance WHERE Training_Hours < 0)),
    ('mp.Overtime_Hours >= 0',                   (SELECT COUNT(*) FROM src_monthly_performance WHERE Overtime_Hours < 0)),
    ('mp.Absenteeism_Days [0..31]',              (SELECT COUNT(*) FROM src_monthly_performance WHERE Absenteeism_Days NOT BETWEEN 0 AND 31)),
    ('mp.Monthly_Bonus >= 0',                    (SELECT COUNT(*) FROM src_monthly_performance WHERE Monthly_Bonus < 0)),
    ('mp.Benefits_Cost >= 0',                    (SELECT COUNT(*) FROM src_monthly_performance WHERE Benefits_Cost < 0)),
    ('rk.Productivity_Index >= 0',               (SELECT COUNT(*) FROM src_role_kpis           WHERE Productivity_Index < 0)),
    ('bo.Sales_Target > 0',                      (SELECT COUNT(*) FROM src_business_outcomes   WHERE Sales_Target <= 0)),
    ('bo.Sales_Actual > 0',                      (SELECT COUNT(*) FROM src_business_outcomes   WHERE Sales_Actual <= 0)),
    ('bo.Customer_Satisfaction [1..10]',         (SELECT COUNT(*) FROM src_business_outcomes   WHERE Customer_Satisfaction NOT BETWEEN 1 AND 10)),
    ('bo.Nps_Score [-100..100]',                 (SELECT COUNT(*) FROM src_business_outcomes   WHERE Nps_Score NOT BETWEEN -100 AND 100)),
    ('bo.Waste_Percentage [0..100]',             (SELECT COUNT(*) FROM src_business_outcomes   WHERE Waste_Percentage NOT BETWEEN 0 AND 100)),
    ('bo.On_Time_Delivery [0..100]',             (SELECT COUNT(*) FROM src_business_outcomes   WHERE On_Time_Delivery NOT BETWEEN 0 AND 100))
) t(col, violations);
    /*  All PASS */

-- Check Age reference date
    -- Test two hypotheses:
        -- (A) Age is a snapshot at 2024-12-31.
        -- (B) Age is age-at-hire.
SELECT
    ROUND(MIN(Age - DATE_DIFF('day', strptime(Hire_Date,'%d/%m/%Y'), DATE '2024-12-31')/365.25),1) AS hypA_min_age_at_hire,
    COUNT(*) FILTER (WHERE Age - DATE_DIFF('day', strptime(Hire_Date,'%d/%m/%Y'), DATE '2024-12-31')/365.25 < 16) AS hypA_implausible,
    ROUND(MAX(Age + DATE_DIFF('day', strptime(Hire_Date,'%d/%m/%Y'), DATE '2024-12-31')/365.25),1) AS hypB_max_age_now,
    COUNT(*) FILTER (WHERE Age + DATE_DIFF('day', strptime(Hire_Date,'%d/%m/%Y'), DATE '2024-12-31')/365.25 > 70) AS hypB_implausible
FROM src_employees;
    /*  Hypothesis A is plausible; Hypothesis B implies implausibly high current ages.
        Decision: treat Age as a snapshot at 2024-12-31 (assumption). */


/* 1.7 TEMPORAL INTEGRITY */

-- Date parsing and hire/exit consistency
SELECT
    COUNT(*) FILTER (WHERE Hire_Date IS NOT NULL AND strptime(Hire_Date,'%d/%m/%Y') IS NULL) AS hire_unparsed
    , COUNT(*) FILTER (WHERE Exit_Date IS NOT NULL AND strptime(Exit_Date,'%d/%m/%Y') IS NULL) AS exit_unparsed
    , COUNT(*) FILTER (WHERE strptime(Exit_Date,'%d/%m/%Y') < strptime(Hire_Date,'%d/%m/%Y'))  AS exit_before_hire
    , MIN(CAST(strptime(Hire_Date,'%d/%m/%Y') AS DATE)) AS hire_min
    , MAX(CAST(strptime(Hire_Date,'%d/%m/%Y') AS DATE)) AS hire_max
FROM src_employees;
    /*  All dates parse successfully and no Exit_Date precedes Hire_Date.
        Hire dates range from 2012-01-04 to 2022-01-01 */

-- Panel period 
SELECT
    MIN(Year_Month)              AS panel_start
    , MAX(Year_Month)            AS panel_end
    , COUNT(DISTINCT Year_Month) AS n_months
FROM src_monthly_performance;
    /*  Panel period: 2022-01 to 2024-12 (36 months) */

-- Monthly Contiguity
SELECT COUNT(*) AS employees_with_gaps
FROM(
    SELECT Employee_Id 
    FROM src_monthly_performance 
    GROUP BY Employee_Id
    HAVING COUNT(*) <> DATE_DIFF('month',
        strptime(MIN(Year_Month)||'-01','%Y-%m-%d'),
        strptime(MAX(Year_Month)||'-01','%Y-%m-%d')
    ) + 1
);
    /* No employee-level gaps detected -> ROWS-based rolling windows are safe. */


/* 1.8 CROSS-FIELD CONSISTENCY —  the geography conflict */
SELECT 
    COUNT(*) AS employees
    , COUNT(*) FILTER (WHERE e.Store_Location <> s.City)                           AS city_mismatches
    , ROUND(100* COUNT(*) FILTER (WHERE e.Store_Location <> s.City) / COUNT(*), 1) AS pct_mismatch
FROM src_employees e JOIN src_stores s USING (Store_Id);
    /* ~96% mismatch - The two geography fields are inconsistent. */

-- Compare internal consistency and supporting evidence for each geography source
SELECT
    (SELECT COUNT(*) FROM (SELECT Store_Location FROM src_employees GROUP BY Store_Location
                           HAVING COUNT(DISTINCT (Store_Location_Latitude, Store_Location_Longitude)) > 1))
                                                                          AS emp_cities_with_multiple_coords,
    (SELECT COUNT(*) FROM (SELECT City           FROM src_stores    GROUP BY City
                           HAVING COUNT(DISTINCT (City_Latitude, City_Longitude)) > 1))
                                                                          AS store_cities_with_multiple_coords,
    (SELECT COUNT(*) FROM src_stores WHERE starts_with(Store_Name, City)) AS store_names_corroborating_city,
    (SELECT COUNT(*) FROM src_stores)                                     AS total_stores;
    
    /*  No conflicting city-to-coordinate mappings found.
        Store_Name corroborates stores.City for all 150 stores.
        Decision: use stores.City for downstream geography. */

