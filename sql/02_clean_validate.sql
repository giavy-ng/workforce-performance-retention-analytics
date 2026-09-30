INSTALL excel;
LOAD excel;

/* 2.1 stg_employees
    Transformations based on findings from 01:
   - Remove employee-level geography fields; use Store_Id -> stores.City as the geography source (1.8).
   - Remove Manager_Name; manager attributes can be recovered via Manager_Id -> Employee_Id (1.3).
   - Rename Manager_Status -> manager_job_level based on its match with the manager's Job_Level (1.3).
   - Standardise '_' to ' ' in Job_Level and manager_job_level for consistent vocabulary (1.3).
   - Parse dates explicitly as dd/mm/yyyy and cast salary to DECIMAL(12,2).*/
CREATE OR REPLACE TABLE stg_employees AS
SELECT
    trim(Employee_Id)                          AS employee_id,
    trim(Full_Name)                            AS full_name,
    CAST(Age AS SMALLINT)                      AS age,
    trim(Education_Level)                      AS education_level,
    strptime(Hire_Date, '%d/%m/%Y')::DATE      AS hire_date,
    strptime(Exit_Date, '%d/%m/%Y')::DATE      AS exit_date,        -- NULL = still employed
    trim(Department)                           AS department,
    trim(Job_Role)                             AS job_role,
    replace(trim(Job_Level), '_', ' ')         AS job_level,
    trim(Employment_Type)                      AS employment_type,
    CAST(Base_Salary_Annual AS DECIMAL(12,2))  AS base_salary_annual,
    trim(Store_Id)                             AS store_id,
    trim(Manager_Id)                           AS manager_id,       -- NULL = top of hierarchy
    replace(trim(Manager_Status), '_', ' ')    AS manager_job_level
FROM read_xlsx('data/data_raw.xlsx', sheet = 'employees');


/*  2.2 stg_stores 
    Retain stores as the authoritative source for store geography (1.8) */
CREATE OR REPLACE TABLE stg_stores AS
SELECT
    trim(Store_Id)                           AS store_id,
    trim(Store_Name)                         AS store_name,
    trim(City)                               AS city,
    City_Latitude                            AS city_latitude,
    City_Longitude                           AS city_longitude,
    trim(Store_Type)                         AS store_type,
    strptime(Opening_Date, '%d/%m/%Y')::DATE AS opening_date
FROM read_xlsx('data/data_raw.xlsx', sheet = 'stores');


/*  2.3 stg_monthly_performance 
    Standardise identifiers, period fields, and numeric data types */
CREATE OR REPLACE TABLE stg_monthly_performance AS
SELECT
    trim(Employee_Id)                               AS employee_id,
    trim(Year_Month)                                AS year_month,
    strptime(Year_Month || '-01', '%Y-%m-%d')::DATE AS period_month,
    Performance_Rating                              AS performance_rating,
    CAST(Training_Hours   AS INTEGER)               AS training_hours,
    CAST(Overtime_Hours   AS INTEGER)               AS overtime_hours,
    CAST(Absenteeism_Days AS INTEGER)               AS absenteeism_days,
    Promotion_Flag                                  AS promotion_flag,
    Salary_Increase_Flag                            AS salary_increase_flag,
    CAST(Monthly_Bonus AS DECIMAL(12,2))            AS monthly_bonus,
    CAST(Benefits_Cost AS DECIMAL(12,2))            AS benefits_cost,
    Employee_Satisfaction                           AS employee_satisfaction,
    Engagement_Index                                AS engagement_index,
    Manager_Evaluation                              AS manager_evaluation
FROM read_xlsx('data/data_raw.xlsx', sheet = 'monthly_performance');


/* 2.4 stg_role_kpis 
    Standardise identifiers, period fields, and KPI labels */
CREATE OR REPLACE TABLE stg_role_kpis AS
SELECT
    trim(Employee_Id)                               AS employee_id,
    trim(Year_Month)                                AS year_month,
    strptime(Year_Month || '-01', '%Y-%m-%d')::DATE AS period_month,
    Kpi_1_Value                                     AS kpi_1_value,
    trim(Kpi_1_Name)                                AS kpi_1_name,
    Kpi_2_Value                                     AS kpi_2_value,
    trim(Kpi_2_Name)                                AS kpi_2_name,
    Kpi_3_Value                                     AS kpi_3_value,
    trim(Kpi_3_Name)                                AS kpi_3_name,
    Productivity_Index                              AS productivity_index
FROM read_xlsx('data/data_raw.xlsx', sheet = 'role_kpis');


/* 2.5 stg_business_outcomes 
    Standardise identifiers, period fields, and numeric data types */
CREATE OR REPLACE TABLE stg_business_outcomes AS
SELECT
    trim(Store_Id)                                  AS store_id,
    trim(Department)                                AS department,
    trim(Year_Month)                                AS year_month,
    strptime(Year_Month || '-01', '%Y-%m-%d')::DATE AS period_month,
    CAST(Sales_Target AS DECIMAL(14,2))             AS sales_target,
    CAST(Sales_Actual AS DECIMAL(14,2))             AS sales_actual,
    Customer_Satisfaction                           AS customer_satisfaction,
    Nps_Score                                       AS nps_score,
    Waste_Percentage                                AS waste_percentage,
    On_Time_Delivery                                AS on_time_delivery
FROM read_xlsx('data/data_raw.xlsx', sheet = 'business_outcomes');


/* 2.6 POST-CLEAN VALIDATION 
    Confirm that cleaning preserved data integrity and applied the intended transformations.*/
SELECT check_name, actual, expected,
       CASE WHEN actual IS NOT DISTINCT FROM expected THEN 'PASS' ELSE 'FAIL' END AS result
FROM (VALUES
    -- Row counts preserved
    ('employees rows preserved',
     (SELECT COUNT(*) FROM stg_employees),
     (SELECT COUNT(*) FROM read_xlsx('data/data_raw.xlsx', sheet='employees'))),
    ('stores rows preserved',
     (SELECT COUNT(*) FROM stg_stores),
     (SELECT COUNT(*) FROM read_xlsx('data/data_raw.xlsx', sheet='stores'))),
    ('monthly_performance rows preserved',
     (SELECT COUNT(*) FROM stg_monthly_performance),
     (SELECT COUNT(*) FROM read_xlsx('data/data_raw.xlsx', sheet='monthly_performance'))),
    ('role_kpis rows preserved',
     (SELECT COUNT(*) FROM stg_role_kpis),
     (SELECT COUNT(*) FROM read_xlsx('data/data_raw.xlsx', sheet='role_kpis'))),
    ('business_outcomes rows preserved',
     (SELECT COUNT(*) FROM stg_business_outcomes),
     (SELECT COUNT(*) FROM read_xlsx('data/data_raw.xlsx', sheet='business_outcomes'))),

    -- Grain preserved
    ('employees.employee_id unique',
     (SELECT COUNT(*) FROM stg_employees), (SELECT COUNT(DISTINCT employee_id) FROM stg_employees)),
    ('stores.store_id unique',
     (SELECT COUNT(*) FROM stg_stores), (SELECT COUNT(DISTINCT store_id) FROM stg_stores)),
    ('monthly_performance grain unique',
     (SELECT COUNT(*) FROM stg_monthly_performance),
     (SELECT COUNT(DISTINCT (employee_id, year_month)) FROM stg_monthly_performance)),
    ('role_kpis grain unique',
     (SELECT COUNT(*) FROM stg_role_kpis),
     (SELECT COUNT(DISTINCT (employee_id, year_month)) FROM stg_role_kpis)),
    ('business_outcomes grain unique',
     (SELECT COUNT(*) FROM stg_business_outcomes),
     (SELECT COUNT(DISTINCT (store_id, department, year_month)) FROM stg_business_outcomes)),

    -- Referential integrity preserved
    ('panel employee_id resolves to employees', 0,
     (SELECT COUNT(*) FROM stg_monthly_performance
      WHERE employee_id NOT IN (SELECT employee_id FROM stg_employees))),
    ('employee store_id resolves to stores', 0,
     (SELECT COUNT(*) FROM stg_employees
      WHERE store_id NOT IN (SELECT store_id FROM stg_stores))),
    ('manager_id resolves to employees', 0,
     (SELECT COUNT(*) FROM stg_employees
      WHERE manager_id IS NOT NULL AND manager_id NOT IN (SELECT employee_id FROM stg_employees))),

    -- Cleaning / transformation checks
    ('period_month fully populated', 0, (SELECT COUNT(*) FROM stg_monthly_performance WHERE period_month IS NULL)),
    ('job_level separator normalised', 0,
     (SELECT COUNT(*) FROM stg_employees WHERE job_level LIKE '%\_%' ESCAPE '\')),
    ('manager_job_level shares job_level vocabulary', 0,
     (SELECT COUNT(*) FROM stg_employees
      WHERE manager_job_level IS NOT NULL
        AND manager_job_level NOT IN (SELECT DISTINCT job_level FROM stg_employees))),
) t(check_name, actual, expected);