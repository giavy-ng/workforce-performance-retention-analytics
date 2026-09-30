-- DIMENSIONS

/* 3.1  dim_date  -- 36 rows, one per month */
CREATE OR REPLACE TABLE dim_date AS
WITH months AS (SELECT DISTINCT period_month, year_month FROM stg_monthly_performance)
SELECT
    period_month,
    year_month,
    ROW_NUMBER() OVER (ORDER BY period_month)            AS month_index,
    YEAR(period_month)                                   AS year,
    MONTH(period_month)                                  AS month,
    MONTHNAME(period_month)                              AS month_name,
    QUARTER(period_month)                                AS quarter,
    YEAR(period_month) || '-Q' || QUARTER(period_month)  AS year_quarter
FROM months;


/* 3.2  dim_department  -- 9 rows */
CREATE OR REPLACE TABLE dim_department AS
SELECT DISTINCT department
FROM stg_employees
ORDER BY department;


/* 3.3  dim_city  -- 25 rows */
CREATE OR REPLACE TABLE dim_city AS
SELECT
    DENSE_RANK() OVER (ORDER BY city) AS city_id,
    city,
    city_latitude,
    city_longitude
FROM (SELECT DISTINCT city, city_latitude, city_longitude FROM stg_stores);


/* 3.4  dim_store  -- 150 rows */
CREATE OR REPLACE TABLE dim_store AS
SELECT
    s.store_id,
    s.store_name,
    ct.city_id,
    s.store_type,
    s.opening_date
FROM stg_stores s
LEFT JOIN dim_city ct ON ct.city = s.city;


/* 3.5  dim_employee  -- 7,086 rows 
    Analytical population is scoped to Jan-2022 → Dec-2024. 
    Excludes 414 employees who exited before the panel start and 
        therefore have no performance records within the analysis period. */
CREATE OR REPLACE TABLE dim_employee AS
SELECT
    employee_id,
    full_name,
    age,
    education_level,
    department,
    job_role,
    job_level,
    employment_type,
    store_id,
    manager_id,
    hire_date,
    exit_date,
    (exit_date IS NULL) AS is_active,
    base_salary_annual
FROM stg_employees
WHERE exit_date IS NULL
   OR exit_date >= (SELECT MIN(period_month) FROM dim_date);


/* 3.6  dim_manager  -- 50 rows */
CREATE OR REPLACE TABLE dim_manager AS
WITH reports AS (
    SELECT manager_id,
           COUNT(*)                   AS span_of_control,
           COUNT(DISTINCT department) AS departments_managed,
           COUNT(DISTINCT store_id)   AS stores_managed
    FROM dim_employee
    WHERE manager_id IS NOT NULL
    GROUP BY manager_id
)
SELECT
    r.manager_id,
    m.full_name  AS manager_name,
    m.job_level  AS manager_job_level,
    m.department AS manager_department,
    m.store_id   AS manager_store_id,
    r.span_of_control,
    r.departments_managed,
    r.stores_managed
FROM reports r
JOIN dim_employee m ON m.employee_id = r.manager_id;

-- FACT TABLES

/* 3.7  fact_employee_month (236,591 rows) -- one employee x one month */
CREATE OR REPLACE TABLE fact_employee_month AS
SELECT
    -- keys / foreign keys
    mp.employee_id,
    mp.period_month,
    e.store_id,
    e.department,
    e.manager_id,

    -- atomic monthly performance measures
    mp.performance_rating,
    mp.manager_evaluation,
    mp.employee_satisfaction,
    mp.engagement_index,
    mp.training_hours,
    mp.overtime_hours,
    mp.absenteeism_days,
    mp.promotion_flag,
    mp.salary_increase_flag,
    mp.monthly_bonus,
    mp.benefits_cost,

    -- role KPIs
    rk.productivity_index,
    rk.kpi_1_name,
    rk.kpi_1_value,
    rk.kpi_2_name,
    rk.kpi_2_value,
    rk.kpi_3_name,
    rk.kpi_3_value
FROM stg_monthly_performance mp
JOIN stg_role_kpis rk ON rk.employee_id = mp.employee_id AND rk.period_month = mp.period_month
JOIN dim_employee e  ON e.employee_id  = mp.employee_id;


/* 3.8  fact_store_department_month (16,200 rows) -- one store x one department x one month */
CREATE OR REPLACE TABLE fact_store_department_month AS
SELECT
    store_id,
    department,
    period_month,
    sales_target,
    sales_actual,
    customer_satisfaction,
    nps_score,
    waste_percentage,
    on_time_delivery
FROM stg_business_outcomes;
