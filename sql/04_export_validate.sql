/*  4.1  DATA MODEL VALIDATION 
    Validate the final dimensions and facts before exporting to Power BI */
SELECT check_name, actual, expected,
       CASE WHEN actual IS NOT DISTINCT FROM expected THEN 'PASS' ELSE 'FAIL' END AS result
FROM (VALUES
    /* ---- 1. Fact grain ---- */
    ('fact_employee_month grain unique',
     (SELECT COUNT(*) FROM fact_employee_month),
     (SELECT COUNT(DISTINCT (employee_id, period_month)) FROM fact_employee_month)),

    ('fact_store_department_month grain unique',
     (SELECT COUNT(*) FROM fact_store_department_month),
     (SELECT COUNT(DISTINCT (store_id, department, period_month)) FROM fact_store_department_month)),

    /* ---- 2. Dimension key uniqueness ---- */
    ('dim_date.period_month unique',
     (SELECT COUNT(*) FROM dim_date),
     (SELECT COUNT(DISTINCT period_month) FROM dim_date)),

    ('dim_department.department unique',
     (SELECT COUNT(*) FROM dim_department),
     (SELECT COUNT(DISTINCT department) FROM dim_department)),

    ('dim_city.city_id unique',
     (SELECT COUNT(*) FROM dim_city),
     (SELECT COUNT(DISTINCT city_id) FROM dim_city)),

    ('dim_store.store_id unique',
     (SELECT COUNT(*) FROM dim_store),
     (SELECT COUNT(DISTINCT store_id) FROM dim_store)),

    ('dim_employee.employee_id unique',
     (SELECT COUNT(*) FROM dim_employee),
     (SELECT COUNT(DISTINCT employee_id) FROM dim_employee)),

    ('dim_manager.manager_id unique',
     (SELECT COUNT(*) FROM dim_manager),
     (SELECT COUNT(DISTINCT manager_id) FROM dim_manager)),

    /* ---- 3. Analytical population scope (Jan-2022 -> Dec-2024) ---- */
    ('dim_employee excludes pre-panel exits', 0,
     (SELECT COUNT(*) FROM dim_employee
      WHERE exit_date < (SELECT MIN(period_month) FROM dim_date))),
 
    ('dim_employee population matches scope rule',
     (SELECT COUNT(*) FROM dim_employee),
     (SELECT COUNT(*) FROM stg_employees
      WHERE exit_date IS NULL
         OR exit_date >= (SELECT MIN(period_month) FROM dim_date))),
 
    ('dim_employee population matches fact panel',
     (SELECT COUNT(*) FROM dim_employee),
     (SELECT COUNT(DISTINCT employee_id) FROM fact_employee_month)),
 
    ('dim_manager span_of_control reconciles to analytical population',
     (SELECT SUM(span_of_control) FROM dim_manager),
     (SELECT COUNT(*) FROM dim_employee WHERE manager_id IS NOT NULL)),

    /* ---- 4. Key relationships ---- */
    ('fact_employee_month.employee_id resolves', 0,
     (SELECT COUNT(*) FROM fact_employee_month
      WHERE employee_id NOT IN (SELECT employee_id FROM dim_employee))),

    ('fact_employee_month.period_month resolves', 0,
     (SELECT COUNT(*) FROM fact_employee_month
      WHERE period_month NOT IN (SELECT period_month FROM dim_date))),

    ('fact_employee_month.store_id resolves', 0,
     (SELECT COUNT(*) FROM fact_employee_month
      WHERE store_id NOT IN (SELECT store_id FROM dim_store))),

    ('fact_store_department_month.store_id resolves', 0,
     (SELECT COUNT(*) FROM fact_store_department_month
      WHERE store_id NOT IN (SELECT store_id FROM dim_store))),

    ('fact_store_department_month.period_month resolves', 0,
     (SELECT COUNT(*) FROM fact_store_department_month
      WHERE period_month NOT IN (SELECT period_month FROM dim_date))),

    /* ---- 5. Source-to-fact reconciliation ---- */
    ('employee monthly bonus reconciles',
     (SELECT CAST(ROUND(SUM(monthly_bonus), 2) AS DECIMAL(18,2)) FROM fact_employee_month),
     (SELECT CAST(ROUND(SUM(monthly_bonus), 2) AS DECIMAL(18,2)) FROM stg_monthly_performance)),

    ('productivity_index reconciles',
     (SELECT CAST(ROUND(SUM(productivity_index), 4) AS DECIMAL(18,4)) FROM fact_employee_month),
     (SELECT CAST(ROUND(SUM(productivity_index), 4) AS DECIMAL(18,4)) FROM stg_role_kpis r INNER JOIN dim_employee e ON r.employee_id = e.employee_id)),

    ('sales_actual reconciles',
     (SELECT CAST(ROUND(SUM(sales_actual), 2) AS DECIMAL(18,2)) FROM fact_store_department_month),
     (SELECT CAST(ROUND(SUM(sales_actual), 2) AS DECIMAL(18,2)) FROM stg_business_outcomes))

) t(check_name, actual, expected)
ORDER BY result, check_name;

SELECT
    COUNT(*) AS rows,
    COUNT(DISTINCT r.employee_id) AS employees,
    ROUND(SUM(r.productivity_index), 4) AS productivity_sum
FROM stg_role_kpis r
INNER JOIN dim_employee e
    ON r.employee_id = e.employee_id
WHERE r.period_month >= DATE '2022-01-01'
  AND r.period_month <= DATE '2024-12-30';

SELECT
    COUNT(*) AS rows,
    COUNT(DISTINCT r.employee_id) AS employees,
    ROUND(SUM(productivity_index), 4) AS productivity_sum
FROM stg_role_kpis r
INNER JOIN dim_employee e
    ON r.employee_id = e.employee_id;

SELECT
  COUNT(*) AS rows,
  COUNT(DISTINCT employee_id) AS employees,
  ROUND(SUM(productivity_index), 4) AS productivity_sum
FROM fact_employee_month;
/* 4.2 EXPORT TO PARQUET */
COPY dim_date                    TO 'data/pbi/dim_date.parquet'                    (FORMAT PARQUET);
COPY dim_department              TO 'data/pbi/dim_department.parquet'              (FORMAT PARQUET);
COPY dim_city                    TO 'data/pbi/dim_city.parquet'                    (FORMAT PARQUET);
COPY dim_store                   TO 'data/pbi/dim_store.parquet'                   (FORMAT PARQUET);
COPY dim_employee                TO 'data/pbi/dim_employee.parquet'                (FORMAT PARQUET);
COPY dim_manager                 TO 'data/pbi/dim_manager.parquet'                 (FORMAT PARQUET);
COPY fact_employee_month         TO 'data/pbi/fact_employee_month.parquet'         (FORMAT PARQUET);
COPY fact_store_department_month TO 'data/pbi/fact_store_department_month.parquet' (FORMAT PARQUET);


-- Final clean analytical model ready for Power BI !!!

