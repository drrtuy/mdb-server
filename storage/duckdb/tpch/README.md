# TPC-H kit — DuckDB storage engine (MariaDB)

Reproducible TPC-H pipeline for the DuckDB storage engine: install a generator,
generate data, create the tables, load them, and run the 22 queries — all
executed directly through the `mariadb` client against `ENGINE=DUCKDB` tables
(no `run_in_duckdb` UDF).

## Pipeline

| Step | Script | What it does |
|---|---|---|
| 1 | `01_install.sh` | Install `tpchgen-cli` (pip / uv / cargo). |
| 2 | `02_generate.sh` | Generate `.tbl` data at scale factor `$SF` into `$DATA_DIR`. |
| 3 | `03_schema.sh` | Create database `$SCHEMA` + 8 `ENGINE=DUCKDB` tables. |
| 4 | `04_load.sh` | `LOAD DATA LOCAL INFILE` each `.tbl` into `$SCHEMA.*`; prints per-table timings + row counts. |
| 5 | `05_run_queries.sh` | Run the 22 queries from `$TPCH_SQL`; writes `query_timings.tsv`. |

Run everything: `./run_all.sh` (steps are idempotent; generation is skipped if data exists).

## Configuration

All knobs live in `config.sh` and are overridable via environment:

```bash
SF=1 ./run_all.sh                      # scale factor 1
DATA_DIR=/data/tpch SF=10 ./run_all.sh # custom data location
SCHEMA=tpch_bench ./03_schema.sh       # custom MariaDB database
```

| Var | Default | Meaning |
|---|---|---|
| `SF` | `10` | TPC-H scale factor |
| `DATA_DIR` | `/git/tpch/sf<SF>` | where `.tbl` files are generated/read |
| `SCHEMA` | `bench` | MariaDB database holding the `ENGINE=DUCKDB` tables |
| `TPCH_SQL` | `/tpch.sql` | source of the 22 (MariaDB-dialect) queries |
| `MARIADB` | `mariadb` | client command |

## Prerequisites

- A running MariaDB server with the DuckDB storage engine loaded
  (`ENGINE=DUCKDB` available).
- `local_infile=ON` on the server so `LOAD DATA LOCAL INFILE` works (the client
  is invoked with `--local-infile=1`).
- `pip`, `uv`, or `cargo` to install the generator; `tpchgen-cli` on `PATH`
  afterwards (pip user installs land in `~/.local/bin`).

## How it works / caveats

- **Generator:** `tpchgen-cli -s <SF> --output-dir <DATA_DIR>` emits classic
  `.tbl` files (pipe-delimited, no header, trailing `|`).
- **Load target:** data goes into `ENGINE=DUCKDB` tables in a regular MariaDB
  database (`bench`), loaded with `LOAD DATA LOCAL INFILE`. The trailing `|` of
  the `.tbl` format is consumed by `LINES TERMINATED BY '|\n'`.
- **Queries:** taken from `$TPCH_SQL` (MariaDB dialect) and executed directly
  through the `mariadb` client with `$SCHEMA` as the default database. Any
  query that errors out is reported as `ERR` in the timings.
