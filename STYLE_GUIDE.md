# Erik Darling's T-SQL Coding Style Guide

This document outlines the T-SQL coding style preferences for Erik Darling (Darling Data, LLC) and must be strictly followed when writing or modifying SQL code.

## Project Constraints

- **No Additional Dependencies**: Do not create helper functions, procedures, views, or any other database objects as dependencies for stored procedures. All logic must be self-contained within the procedure itself to avoid deployment and dependency management complexity.

## General Formatting

- **Keywords**: All SQL keywords in UPPERCASE (SELECT, FROM, WHERE, JOIN, etc.)
- **Functions**: All SQL functions in UPPERCASE (CONVERT, ISNULL, OBJECT_ID, etc.)
- **Data types**:
  - Never abbreviate data types (use INTEGER instead of INT)
  - All data types must be lowercase (varchar, nvarchar, datetime2, bigint, etc.)
  - Length specifications must also be lowercase: nvarchar(max), not nvarchar(MAX)
  - Precision and scale specifications must be lowercase: decimal(38,2), not DECIMAL(38,2)
  - Always use sysname for SQL Server object names (database names, table names, schema names, column names, index names, etc.) rather than nvarchar(128)
- **Keywords**: Never abbreviate keywords (use EXECUTE instead of EXEC, TRANSACTION instead of TRAN, PROCEDURE instead of PROC)
- **Indentation**: 4 spaces for each level of indentation (NEVER use tabs)
- **Line breaks**: Each statement on a new line
- **Spacing**: Consistent spacing around operators (=, <, >, etc.)
- **Block separation**: Empty line between logical code blocks (maximum of two empty lines between statements)
- **Quotes**: Use single quotes for string literals and N-prefix for Unicode strings (N'string')
- **TOP syntax**: Always include parentheses, as in TOP (100) not TOP 100
- **Object creation**: Generally use CREATE OR ALTER for objects instead of DROP/CREATE
- **Table aliases**: Tables must always have aliases, even in simple queries
- **Column references**: Always qualify columns with their table alias
- **Commas**: Trailing commas always.

## Comments

- Always use block comments with /* ... */ for most comments, never use double dash (--)
- Include parameter descriptions as inline comments after parameter definitions
- Use ASCII art for header blocks to visually distinguish sections
- Include copyright and attribution information in header comments
- Prefix code sections with descriptive comments about what the section does
- Use comments to describe:
  - New code blocks
  - Complex expressions
  - Table purposes
  - Complex logic
  - The logical flow of code

## Naming Conventions

- **Parameters**: Prefixed with @ and use snake_case (@database_name, @debug)
- **Variables**: Same as parameters (@database_id, @sql)
- **Temporary Tables**: Prefixed with # and use descriptive snake_case (#filtered_objects)
- **Aliases**: Short, meaningful lowercase names (ap, o, t)
- **Objects**: Use clear, descriptive names

## Query Structure

- **SELECT statements**:
  - SELECT keyword on first line
  - Column list starts on next line, indented four spaces
  - Trailing commas for multi-line column lists
  - Columns aligned vertically for readability
  - FROM clause on new line at same indent level as SELECT
  - Column aliases should always use the pattern: column_name = column_expression
    - Example: some_date = DATEADD(DAY, 1, GETDATE())
  - Always terminate queries with a semicolon

- **Table references**:
  - Always use schema prefixes for all objects except temporary objects
  - Examples: FROM dbo.objects, FROM tempdb.dbo.objects
  - Temporary tables don't need schema: FROM #temp_table

- **Table aliases**:
  - Always use the AS keyword with table aliases: table_name AS alias
  - Example: FROM dbo.sys_objects AS o

- **Windowing functions**:
  - Format with OVER on same line as function
  - PARTITION BY and ORDER BY on separate lines indented
  - Parentheses on their own lines
  ```sql
  SELECT
      n = ROW_NUMBER() OVER
          (
              PARTITION BY
                  column_name
              ORDER BY
                  other_column
          )
  ```

- **JOIN syntax**:
  - Use modern ANSI JOIN syntax (JOIN table ON condition)
  - JOIN keyword on new line at same indent level as FROM
  - ON conditions indented from JOIN
  - JOIN conditions with AND should be aligned like this:
  ```sql
  FROM dbo.table_a AS a0
  JOIN dbo.table_a AS a1
    ON  a0.col = a1.col
    AND a0.col = a1.col
  ```
  - For correlated queries and joins, the table most recently referenced should come first in the ON clause:
  ```sql
  FROM first_table AS ft0
  JOIN dbo.first_table AS ft1
    ON ft1.col = ft0.col
  ```

- **Clauses**:
  - GROUP BY, ORDER BY, and HAVING clauses should always begin on a new line, indented four spaces from the main statement
  - WHERE clauses with AND conditions should be formatted with AND aligned:
  ```sql
  WHERE a.col = 1
  AND   b.col = 2
  ```
  - EXISTS and NOT EXISTS should use this format with 1/0 in the SELECT:
  ```sql
  WHERE EXISTS
  (
      SELECT
          1/0
      FROM other_table AS ot
      WHERE ot.col = t.col
  )
  ```

- **Subqueries**:
  - Subqueries should never be one-liners
  - Place on new lines with proper indentation
  ```sql
  SELECT
      column_name =
      (
          SELECT
              column_name
          FROM dbo.table_name AS alias
          WHERE condition
      )
  ```

- **APPLY operators**:
  - Format CROSS APPLY and OUTER APPLY with the query on new lines
  ```sql
  FROM dbo.a_table AS y
  CROSS APPLY
  (
      SELECT
          columns
      FROM dbo.table_name AS x
      WHERE x.col = y.col
  ) AS x
  ```

- **Set operations**:
  - UNION, INTERSECT, EXCEPT should have the operator between statements with blank lines
  ```sql
  SELECT
     a.columns
  FROM dbo.a_table AS a

  EXCEPT

  SELECT
     b.columns
  FROM dbo.b_table AS b;
  ```

- **Table-valued constructors (VALUES)**:
  - Format with VALUES on its own line, and value rows indented:
  ```sql
  FROM
  (
      VALUES
          (1, 2, 3)
  ) AS v (named_columns);
  ```

- **CTEs**:
  - WITH keyword on its own line
  - CTE name indented on next line
  - Opening parenthesis on same line as CTE name
  - Column list indented on subsequent lines
  - Closing parenthesis on its own line
  - AS keyword on its own line
  - Multiple CTEs separated by commas at the end
  ```sql
  WITH
      database_stats
  (
      database_name,
      recovery_model,
      log_size_mb
  ) AS
  (
      SELECT
          database_name = d.name,
          recovery_model = d.recovery_model_desc,
          log_size_mb = SUM(f.size) * 8 / 1024
      FROM sys.databases AS d
      JOIN sys.master_files AS f
        ON f.database_id = d.database_id
      GROUP BY
          d.name,
          d.recovery_model_desc
  ),
  second_cte
  (
      column_list
  ) AS
  (
      query
  )
  ```

- **Table Creation**:
  - CREATE TABLE on first line
  - Schema and table name on next line, indented
  - Opening parenthesis on its own line
  - Each column on a new line, indented
  - Always specify NULL or NOT NULL constraint for each column
  - DEFAULT constraints can generally follow other column descriptors on the same line
  - Closing parenthesis on its own line
  ```sql
  CREATE TABLE
      dbo.table_name
  (
      column_name bigint NOT NULL,
      another_column varchar(50) NULL DEFAULT 'value',
      third_column datetime2(7) NOT NULL DEFAULT SYSDATETIME()
  );
  ```

- **INSERT statements**:
  - INSERT on first line
  - Always use INSERT INTO
  - Schema and table name on next line, indented
  - Column list in parentheses on new lines, indented
  ```sql
  INSERT INTO
      dbo.table_name
  (
      column1,
      column2
  )
  VALUES
  (
      value1,
      value2
  );
  ```

- **Temporary table inserts**:
  - Use TABLOCK hint with temporary table inserts
  ```sql
  INSERT
      #table_name
  WITH
      (TABLOCK)
  (
      column_list
  )
  ```

- **UPDATE statements**:
  - UPDATE on first line
  - Table alias on next line, indented
  - SET on its own line with same indentation as alias
  - FROM clause on its own line
  ```sql
  UPDATE
      alias
  SET
     alias.col1 = value1,
     alias.col2 = value2
  FROM dbo.table AS alias
  WHERE alias.condition;
  ```

- **DELETE statements**:
  - DELETE on first line
  - Table alias on next line, indented
  - FROM clause on its own line
  ```sql
  DELETE
      alias
  FROM dbo.table AS alias
  WHERE alias.condition;
  ```

- **Parentheses**:
  - Opening parenthesis on same line as function/procedure name
  - Closing parenthesis aligned with starting line or on its own line for long expressions
  - Use extra parentheses for clarity in complex expressions
  - Function arguments should be indented four spaces and on new lines:
  ```sql
  CONVERT
  (
      data_type,
      value
  )
  ```

## Code Organization

- SET statements grouped at procedure start
- Validation checks before main logic
- Help/documentation sections clearly separated from main logic
- Version information tracked explicitly
- Parameter validation at beginning of procedures
- CREATE/ALTER statements separated with GO

## Code Blocks and Control Structures

- BEGIN/END contents should be indented four spaces:
  ```sql
  BEGIN
      /*logic*/
  END;
  ```

- CASE expression contents should be indented, with each condition on a new line:
  ```sql
  CASE
      WHEN thing
      AND  other_thing
      THEN stuff
      ELSE result
  END
  ```

- IF/ELSE blocks should be formatted with BEGIN/END on their own lines:
  ```sql
  IF condition
  BEGIN
      logic
  END;
  ELSE
  BEGIN
      logic
  END;
  ```

- Error handling should follow this template:
  ```sql
  BEGIN
      BEGIN TRY
          do stuff
      END TRY
      BEGIN CATCH
          IF @@TRANCOUNT > 0
          BEGIN
              ROLLBACK;
          END;

          THROW;
      END CATCH;
  END;
  ```

- DECLARE blocks should put everything on a new line:
  ```sql
  DECLARE
      @t1 integer,
      @t2 integer;
  ```

- Dynamic SQL should follow specific formatting:
  - Initial declaration with empty string
  - Each string concatenation part on its own line
  - Each QUOTENAME or variable reference on its own line
  ```sql
  DECLARE
      @sql nvarchar(max) = N''

  SET @sql += N'
  SELECT
      column_name =
          value ' +
      QUOTENAME(alias.object_name) + N'
  FROM
      table_name
  ';

  EXECUTE sys.sp_executesql
      @sql,
     N'@parameters',
       @input;
  ```

## SQL Best Practices

- Always use IS NULL / IS NOT NULL for NULL comparisons, never = NULL or != NULL
- Use ISNULL() function for value replacement
- Include RECOMPILE hints for procedures with variable data distributions
- Use RAISERROR with NOWAIT for immediate message display
- Include thorough error handling with BEGIN TRY/CATCH blocks
- Always validate user inputs before using them
- Use semicolons at the end of statements (but only at the very end, after any query hints)
- Apply query hints consistently (RECOMPILE, MAXDOP, etc.)
- Always use ROWCOUNT_BIG() instead of @@ROWCOUNT
- Always use COUNT_BIG() instead of COUNT() to avoid potential integer overflow
  - Example: `COUNT_BIG(i.index_id)` not `COUNT(i.index_id)`
  - Even if the result will never be large enough to overflow, use COUNT_BIG() for consistency
- Always use CONVERT over CAST for data type conversions (except when using TRY_CAST, as TRY_CAST isn't dependent on SQL Server version)
- Prefer temporary tables over table variables for performance reasons
- Do not drop temporary tables at the end of stored procedures (they're automatically cleaned up when the procedure exits)
- Prefer + operator for string concatenation as it's not version dependent
- Date literals should always follow yyyymmdd format (e.g., 20250101)

## sp_HeapDoctor Intentional Deviations

These deviations from the strict Darling style are intentional design choices:

| Item | Darling Style | sp_HeapDoctor Style | Rationale |
|------|---------------|---------------------|-----------|
| Parameter naming | snake_case (@database_name) | PascalCase (@Databases) | Standard T-SQL convention; matches Ola Hallengren patterns |
| Variable naming | snake_case | Mixed (PascalCase for public, snake_case for internal) | Consistency with parameter names |
| Temp table naming | snake_case (#filtered_objects) | PascalCase (#Targets, #Heaps) | Matches established codebase convention |
| EXISTS SELECT | SELECT 1/0 | SELECT 1 | SELECT 1 is more widely understood |

---

*Based on analysis of Erik Darling's stored procedures from Darling Data, LLC.*
