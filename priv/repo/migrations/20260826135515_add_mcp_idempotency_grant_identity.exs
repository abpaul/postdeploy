defmodule Alplus.Repo.Migrations.AddMcpIdempotencyGrantIdentity do
  @moduledoc """
  Scopes MCP idempotency uniqueness by OAuth grant_id.

  grant_id is nullable for browser-session actors. The unique index uses
  NULLS NOT DISTINCT so session rows with a null grant_id still collide on
  (org_id, tool, idempotency_key).
  """

  use Ecto.Migration

  def up do
    alter table(:mcp_idempotency_records) do
      add :grant_id, :text
    end

    drop_if_exists unique_index(:mcp_idempotency_records, [:org_id, :tool, :idempotency_key],
                     name: "mcp_idempotency_records_unique_org_tool_key_index"
                   )

    create unique_index(
             :mcp_idempotency_records,
             [:org_id, :tool, :idempotency_key, :grant_id],
             name: "mcp_idempotency_records_unique_org_tool_key_index",
             nulls_distinct: false
           )
  end

  def down do
    drop_if_exists unique_index(
                     :mcp_idempotency_records,
                     [:org_id, :tool, :idempotency_key, :grant_id],
                     name: "mcp_idempotency_records_unique_org_tool_key_index"
                   )

    alter table(:mcp_idempotency_records) do
      remove :grant_id
    end

    create unique_index(:mcp_idempotency_records, [:org_id, :tool, :idempotency_key],
             name: "mcp_idempotency_records_unique_org_tool_key_index"
           )
  end
end
