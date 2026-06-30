# Pluggable SQL Parser

## Goal

Allow MariaDB to route a query to an alternative parser selected at runtime,
without touching the core Bison grammar. The first consumer is a **DuckDB
passthrough**: send the raw query text to DuckDB, execute it there, and stream
results back to the client. The same mechanism is designed to later support a
PostgreSQL-subset parser that builds MariaDB's internal `LEX`.

A key constraint: **multiple parsers, one AST on the Bison output**. A converter
(foreign AST -> MariaDB `LEX`) is cleaner but adds latency that is unacceptable
for OLTP. Therefore each parser either executes the statement itself or fills
`LEX` directly — there is no intermediate AST conversion step.

## Plugin Type

- New plugin type `MariaDB_PARSER_PLUGIN = 12`.
- Bump `MYSQL_MAX_PLUGIN_TYPE_NUM` -> 13 in `include/mysql/plugin.h`.
- New descriptor header `include/mysql/plugin_parser.h`:
  - interface version
  - `init` / `deinit`
  - a single entry point `handle(THD *thd, const char *query, size_t len)`.

## Dispatch Contract (single parse+dispatch entry)

`handle()` returns an enum:

| Return value         | Meaning                                                        | Core action                                            |
|----------------------|----------------------------------------------------------------|--------------------------------------------------------|
| `PARSER_NOT_MINE`    | Plugin does not handle this statement                          | Fall through to `parse_sql()` (Bison)                  |
| `PARSER_EXECUTED`    | Plugin parsed **and** executed the statement and sent results  | Skip parsing/execution, go straight to cleanup         |
| `PARSER_ERROR`       | Error; plugin already raised `my_error()`                      | Error path (`query_cache_abort`)                       |
| `PARSER_LEX_READY`   | *Reserved.* Plugin filled `LEX`; core executes it              | Not wired in MVP (planned for the PostgreSQL parser)   |

The model is **hybrid**: the plugin decides per command whether to execute it
itself or to route it to `LEX`. The decision lives in the plugin via a literal
`switch` on the plugin's own command enum.

## Plugin Selection

- A system variable (session + global) holds the active parser plugin name.
- Empty value -> pure Bison path, i.e. **zero OLTP overhead** when unused.
- The core resolves the name to a plugin via the plugin registry, filtered by
  plugin type.
- Selection is manual for now: load the plugin, then set the variable. No query
  hints and no `claims()` predicate.

## Core Hook

In `sql/sql_parse.cc`, inside `mysql_parse()`, right after the query cache check
and before `parse_sql()` (around line 7893):

```text
if (active_parser_plugin)
{
  switch (plugin->handle(thd, rawbuf, length))
  {
    case PARSER_EXECUTED:  /* skip parse_sql + mysql_execute_command */ goto cleanup;
    case PARSER_ERROR:     /* error path: query_cache_abort */          goto error;
    case PARSER_NOT_MINE:  /* fall through to Bison */                  break;
    /* PARSER_LEX_READY reserved, not handled in MVP */
  }
}
```

Notes:
- The query cache is consulted **before** the plugin (a cache hit never reaches
  the plugin).
- Multi-statement input (`found_semicolon`) is **not** supported by the plugin.
- The plugin does **not** populate the query cache.

## Command Identity

- The plugin defines its **own** command enum (e.g. `CMD_QUERY`, `CMD_DML`).
- MariaDB's closed `enum_sql_command` is **not** modified.
- For self-executed commands the plugin enum is sufficient.
- For the reserved route-to-`LEX` path, the plugin would set `lex->sql_command`
  to an existing `SQLCOM_*` value.

## DuckDB Passthrough Plugin

The plugin **parses the query once** with DuckDB and reuses that single parse for
classification, privilege checks, and execution. DuckDB does **not** produce a
MariaDB `LEX`; it has its own AST (`SQLStatement`) and bound plan
(`LogicalOperator`). The passthrough therefore executes inside DuckDB on the
DuckDB AST — there is no AST-to-`LEX` conversion.

Relevant DuckDB public API (`duckdb/main/connection.hpp`):
- `ExtractStatements(query)` -> `vector<unique_ptr<SQLStatement>>` (parse only).
- `SQLStatement::type` (`StatementType`) and `SQLStatement::query`.
- `Query(unique_ptr<SQLStatement>)` / `SendQuery(...)` / `Prepare(...)` execute
  an already-parsed statement (no re-parse).
- `ExtractPlan(query)` -> `unique_ptr<LogicalOperator>` (bound logical plan).

Flow of `handle()`:
1. `ExtractStatements(query)` -> a single `SQLStatement`.
2. Classify by `StatementType` (precise, no token sniff):
   - `SELECT_STATEMENT` -> `CMD_QUERY`
   - `INSERT` / `UPDATE` / `DELETE` / `COPY_STATEMENT` -> `CMD_DML`
   - `SET` / `TRANSACTION_STATEMENT` / ... -> return `PARSER_NOT_MINE` (Bison)
3. Privilege check (see below).
4. A literal `switch(cmd)` maps the command to a handler function:
   - `CMD_QUERY` -> execute the parsed statement via `Query(std::move(stmt))` ->
     send metadata + rows via `thd->protocol` -> `my_eof()`
   - `CMD_DML` -> execute via `Query(std::move(stmt))` ->
     `my_ok(thd, affected_rows)`
   - default -> `return PARSER_NOT_MINE`
- The handler **owns all output**: it writes to `thd->protocol` and calls
  `my_ok()` / `my_error()`. The core performs only `end_statement()` / cleanup
  after `PARSER_EXECUTED`.

## Privilege Checks

Because `PARSER_EXECUTED` bypasses `mysql_execute_command()`, it also bypasses
MariaDB's ACL checks. The plugin must re-enforce them before executing in
DuckDB. DuckDB-backed tables are the **same** MariaDB tables (storage engine,
with `.frm` and GRANTs), so `(db, table)` names map to real MariaDB GRANT
entries.

MariaDB ACL entry points operate on `(db, table)` strings plus a `TABLE_LIST`,
not on a fully parsed `LEX`:
- `check_table_access(thd, want_access, table_list, ...)` (`sql/sql_parse.cc`).
- `check_grant(thd, want_access, table, ...)`,
  `fill_effective_table_privileges(thd, grant, db, table)` (`sql/sql_acl.cc`).

Approach (single parse, **no extra `GetTableNames` re-parse**):
1. Collect referenced base tables by walking the parsed `SQLStatement` AST (or
   the `LogicalGet` nodes of `ExtractPlan`). This naturally resolves views,
   CTEs, subqueries, and qualified names.
2. Build a minimal `TABLE_LIST(db, table)` (unqualified tables default to the
   current schema, `thd->db`).
3. Call `check_table_access()` with `want_access` derived from the command
   class: `CMD_QUERY` -> `SELECT_ACL`; `CMD_DML` ->
   `INSERT_ACL` / `UPDATE_ACL` / `DELETE_ACL` per statement type.
4. On denial, raise `my_error()` and return `PARSER_ERROR`.

Granularity is **table-level** for the MVP; column-level checks
(`check_grant_all_columns`) are deferred.

## Out of Scope (MVP)

- `PARSER_LEX_READY` / route-to-`LEX` for PostgreSQL (manual `LEX` / `Item` tree
  construction).
- Multi-statement handling inside the plugin.
- Query cache population by the plugin.
- Binlogging of self-executed DML.
- Column-level privilege checks (table-level only in the MVP).
- Prepared statements for self-executed commands (route-to-`LEX` commands keep
  prepared-statement support once implemented).

## Implementation Order

1. `include/mysql/plugin_parser.h` + `MYSQL_MAX_PLUGIN_TYPE_NUM` bump in
   `include/mysql/plugin.h`.
2. Register the new plugin type in `sql/sql_plugin.cc` (type-name table) and add
   the selection system variable.
3. Add the dispatch hook in `mysql_parse()` (`sql/sql_parse.cc`).
4. Implement the DuckDB passthrough plugin under `storage/duckdb/`:
   `ExtractStatements` -> classify by `StatementType` -> table-level
   `check_table_access` -> command `switch` -> execute the parsed statement and
   stream results.
