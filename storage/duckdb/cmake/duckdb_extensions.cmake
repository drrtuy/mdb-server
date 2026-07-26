# Extensions required by the DuckDB storage engine plugin for MariaDB.
# This config is passed to DuckDB via DUCKDB_EXTENSION_CONFIGS.

duckdb_extension_load(core_functions)
duckdb_extension_load(httpfs
  GIT_URL https://github.com/duckdb/duckdb-httpfs
  GIT_TAG c3f215ab360f04dc3d3d5305fa81849c0121f111)
duckdb_extension_load(icu)
duckdb_extension_load(json)
duckdb_extension_load(quack
  GIT_URL https://github.com/duckdb/duckdb-quack
  GIT_TAG 40de7badae4193c29d9c0834473fb76acc6c51e6)
