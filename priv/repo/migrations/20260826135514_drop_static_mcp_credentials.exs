defmodule Alplus.Repo.Migrations.DropStaticMcpCredentials do
  @moduledoc """
  Drops static MCP credentials.

  Rollback recreates the prior empty schema so older application code can
  boot after `ecto.rollback`. Dropped credential rows are unrecoverable.
  This is not production backward compatibility.
  """

  use Ecto.Migration

  def up do
    drop table(:mcp_credentials)
  end

  def down do
    # Recreates the pre-drop generated schema only. Data cannot be restored.
    create table(:mcp_credentials, primary_key: false) do
      add :id, :text, null: false, primary_key: true

      add :org_id,
          references(:organizations,
            column: :id,
            name: "mcp_credentials_org_id_fkey",
            type: :text,
            prefix: "public",
            on_delete: :delete_all
          ),
          null: false

      add :created_by_user_id,
          references(:users,
            column: :id,
            name: "mcp_credentials_created_by_user_id_fkey",
            type: :text,
            prefix: "public",
            on_delete: :delete_all
          ),
          null: false

      add :project_id,
          references(:projects,
            column: :id,
            name: "mcp_credentials_project_id_fkey",
            type: :text,
            prefix: "public",
            on_delete: :delete_all
          )

      add :name, :text, null: false
      add :token_hash, :text, null: false
      add :token_prefix, :text, null: false
      add :access, :text, null: false, default: "read"
      add :last_used_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:mcp_credentials, [:token_prefix],
             name: "mcp_credentials_unique_token_prefix_index"
           )

    create constraint(:mcp_credentials, :mcp_credentials_active_project_check,
             check: "project_id IS NOT NULL OR revoked_at IS NOT NULL"
           )

    execute("""
    ALTER TABLE mcp_credentials
      ADD CONSTRAINT mcp_credentials_token_hash_check CHECK (token_hash ~ '^[0-9a-f]{64}$'),
      ADD CONSTRAINT mcp_credentials_name_size_check CHECK (octet_length(name) <= 256),
      ADD CONSTRAINT mcp_credentials_token_prefix_size_check CHECK (octet_length(token_prefix) <= 32),
      ADD CONSTRAINT mcp_credentials_access_check CHECK (access IN ('read', 'read_write'))
    """)
  end
end
