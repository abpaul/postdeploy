-- Runs only when Docker initializes the disposable named volume.
-- The primary development database comes from POSTGRES_DB above. The harness
-- creates a new database and schema for each explicit test-worker identifier.
CREATE SCHEMA IF NOT EXISTS app;
