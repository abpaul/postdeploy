defmodule Alplus.Audit.Change do
  @moduledoc """
  Attach to any sensitive action to write one `Alplus.Audit.AuditLog` row
  for it, allowed or denied (ARCHITECTURE.md §14 rule 5):

      update :update do
        ...
        change {Alplus.Audit.Change, action: "organization.update", subject_type: "organization", org_id_attribute: :id}
      end

  Registers `Ash.Changeset.after_transaction/2` inside `change/3`.
  `change/3` runs at changeset-build time, unconditionally — *before*
  policies are checked (`Ash.Changeset.for_create/for_update` runs the
  action's `change`s, then `Ash.create/update/destroy` authorizes the
  result). `after_transaction` hooks then run once the outcome is known, on
  *both* the allow and the deny path: when authorization fails, Ash's own
  `do_run/4` still calls `run_after_transactions/2` on the now-invalid
  changeset. So this one declarative hook covers both rows the
  architecture requires, no matter whether the caller goes through
  `Ash.create/2`, `AshPhoenix.Form`, or a domain code interface — this is
  the same pattern `Ash.Changeset.after_transaction/2`'s own docs use for a
  compliance logger.

  Only an `Ash.Error.Forbidden` outcome is logged as `"denied"`. A plain
  validation failure (bad slug, blank name) is not a security event and is
  not audited.

  Options:

    * `:action` (required) — the audit action string, e.g. `"organization.update"`.
    * `:subject_type` (required) — e.g. `"organization"`, `"membership"`.
    * `:org_id_attribute` — attribute to read the org id from (default `:org_id`).
      Pass `:id` for a resource that *is* the org (`Alplus.Orgs.Organization`).
    * `:project_id_attribute` — attribute to read the project id from
      (default `nil`, meaning "not applicable").

  Reads `changeset.context[:audit]` (a map, default `%{}`) for optional
  `:request_id` / `:user_agent` metadata a caller can attach with
  `Ash.create(..., context: %{audit: %{request_id: ...}})`.
  """

  use Ash.Resource.Change

  @impl true
  def init(opts) do
    with {:ok, action} <- Keyword.fetch(opts, :action),
         {:ok, subject_type} <- Keyword.fetch(opts, :subject_type) do
      {:ok,
       opts
       |> Keyword.put(:action, action)
       |> Keyword.put(:subject_type, subject_type)
       |> Keyword.put_new(:org_id_attribute, :org_id)
       |> Keyword.put_new(:project_id_attribute, nil)}
    else
      :error -> {:error, "Alplus.Audit.Change requires :action and :subject_type"}
    end
  end

  @impl true
  def change(changeset, opts, _context) do
    Ash.Changeset.after_transaction(changeset, fn changeset, result ->
      record(changeset, result, opts)
      result
    end)
  end

  defp record(changeset, {:ok, _record}, opts), do: write(changeset, opts, "allowed")

  defp record(changeset, {:error, error}, opts) do
    if forbidden?(error), do: write(changeset, opts, "denied")
  end

  defp write(changeset, opts, outcome) do
    org_id = resolve_attribute(changeset, opts[:org_id_attribute], outcome)

    # No org exists to attribute this row to — either a denied `create` on
    # a resource whose own row *is* the org/project (its id was never
    # persisted), or `Organization`'s own successful `:destroy` (the org
    # row is already gone by the time this `after_transaction` hook runs).
    # Both cases skip the write rather than let the insert fail on a
    # foreign-key violation: `audit_logs.org_id` is `ON DELETE CASCADE`
    # against `organizations` (founder decision — destroying an org erases
    # its audit trail with it, GDPR-style right to erasure, not a
    # preserved trail), so a row for the destroy event itself would be
    # erased by that same cascade the instant it landed anyway.
    # `resolve_attribute/3` returns `nil` on purpose whenever the id in
    # question would point at a row that does not exist.
    if org_id do
      Alplus.Audit.write(%{
        actor: get_in(changeset.context, [:private, :actor]),
        action: opts[:action],
        outcome: outcome,
        org_id: org_id,
        project_id: project_id(changeset, opts, outcome),
        subject_type: opts[:subject_type],
        subject_id: Ash.Changeset.get_attribute(changeset, :id),
        metadata: get_in(changeset.context, [:audit]) || %{}
      })
    end
  end

  defp project_id(changeset, opts, outcome) do
    case opts[:project_id_attribute] do
      nil -> nil
      attribute -> resolve_attribute(changeset, attribute, outcome)
    end
  end

  # A denied `create` never persisted its own primary key, so reading `:id`
  # from the pending changeset would point an audit row's FK at a row that
  # does not exist — this is the only self-referential case, since
  # `org_id_attribute`/`project_id_attribute` otherwise always name a
  # *different*, already-existing row (a project's `org_id`, an api key's
  # `project_id`, ...), which `get_attribute/2` resolves safely even on a
  # denied create by falling back to `changeset.data`.
  defp resolve_attribute(%Ash.Changeset{action_type: :create}, :id, "denied"), do: nil

  # `Organization`'s own `:destroy` (`org_id_attribute: :id`) is the only
  # *hard*-deleting self-referential destroy audited: this `after_transaction`
  # hook runs once the row is already gone. Skipped for the erasure reason
  # above, not merely "would fail" — even if the insert could succeed, this
  # row would be erased along with the rest of the org's audit trail by the
  # same `ON DELETE CASCADE` a moment later. Scoped to
  # `Alplus.Orgs.Organization` specifically: other `:destroy`-type actions
  # in this codebase (e.g. `Project`'s `:archive`) are soft deletes via
  # `AshArchival` — the row, and its id, still exist after commit, so they
  # must keep resolving normally.
  defp resolve_attribute(
         %Ash.Changeset{action_type: :destroy, resource: Alplus.Orgs.Organization},
         :id,
         "allowed"
       ),
       do: nil

  defp resolve_attribute(changeset, attribute, _outcome),
    do: Ash.Changeset.get_attribute(changeset, attribute)

  defp forbidden?(%mod{} = error) do
    case Module.split(mod) do
      ["Ash", "Error", "Forbidden" | _] -> true
      _ -> nested_forbidden?(error)
    end
  end

  defp forbidden?(_), do: false

  defp nested_forbidden?(%{errors: errors}) when is_list(errors),
    do: Enum.any?(errors, &forbidden?/1)

  defp nested_forbidden?(_), do: false
end
