defmodule Alplus.Mcp.Discovery do
  @moduledoc "Read-only discovery over the canonical internal action registry."

  alias Alplus.Mcp.{Catalog, Cursor, Error, Principal, Schema, Scope, Tenancy, Tool}

  @areas ~w(monitor observe measure changelog status platform)

  @spec context(Principal.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def context(%Principal{} = principal, args) when is_map(args) do
    with {:ok, organization} <-
           Ash.get(Alplus.Orgs.Organization, principal.org_id, authorize?: false) do
      context_for(principal, args, organization)
    else
      _ -> {:error, Error.from(:not_found)}
    end
  end

  def context(_principal, _args), do: {:error, Error.from(:not_found)}

  @spec search(Principal.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def search(%Principal{} = principal, args) when is_map(args) do
    intent = value(args, "intent")
    area = value(args, "area")
    limit = value(args, "limit") || 20

    cond do
      not is_binary(intent) or String.trim(intent) == "" ->
        {:error, Error.from({:invalid_argument, "intent"})}

      not is_nil(area) and area not in @areas ->
        {:error, Error.from({:invalid_argument, "area"})}

      not is_integer(limit) or limit < 1 or limit > 50 ->
        {:error, Error.from({:invalid_argument, "limit"})}

      true ->
        ranked =
          Catalog.all()
          |> Enum.filter(&(public_action?(&1) and area_matches?(&1, area)))
          |> Enum.map(&{score(&1, intent), &1})
          |> Enum.sort_by(fn {match_score, tool} -> {-match_score, tool.name} end)
          |> Enum.take(limit)

        summaries = Enum.map(ranked, fn {_match_score, tool} -> summary(tool, principal) end)
        summaries = maybe_exact_schema(summaries, ranked)
        {:ok, %{"matches" => summaries, "next_cursor" => nil}}
    end
  end

  def search(_principal, _args), do: {:error, Error.from({:invalid_argument, "intent"})}

  @spec get(Principal.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def get(%Principal{} = principal, action) when is_binary(action) do
    case Catalog.get(action) do
      {:ok, _adapter, %Tool{} = tool} -> {:ok, %{"action" => metadata(tool, principal)}}
      {:error, :not_found} -> {:error, Error.from(:not_found)}
    end
  end

  def get(_principal, _action), do: {:error, Error.from(:not_found)}

  @doc "Returns canonical action metadata without tenant data."
  @spec metadata(Tool.t(), Principal.t()) :: map()
  def metadata(%Tool{} = tool, %Principal{} = principal) do
    required_scope = Scope.required(tool) || ""

    %{
      "name" => tool.name,
      "title" => tool.title,
      "description" => tool.description,
      "input_schema" => Schema.stringify(tool.input_schema),
      "output_schema" => Schema.stringify(tool.output_schema),
      "safety" => Atom.to_string(Tool.safety_class(tool)),
      "required_scope" => required_scope,
      "rate_weight" => Tool.cost_weight!(tool),
      "idempotent" => Tool.safety_class(tool) != :read,
      "prerequisites" => tool.prerequisites,
      "examples" => tool.examples,
      "availability" => availability(principal, tool)
    }
  end

  defp summary(%Tool{} = tool, %Principal{} = principal) do
    required_scope = Scope.required(tool) || ""

    %{
      "action" => tool.name,
      "title" => tool.title,
      "description" => tool.description,
      "required_scope" => required_scope,
      "safety" => Atom.to_string(Tool.safety_class(tool)),
      "missing_scope" => missing_scope(principal, tool, required_scope)
    }
  end

  defp maybe_exact_schema([top | rest], [{top_score, _tool} | ranked_rest]) do
    second_score =
      case ranked_rest do
        [{score, _} | _] -> score
        [] -> nil
      end

    if is_nil(second_score) or top_score > second_score do
      [Map.put(top, "input_schema", action_schema(top)) | rest]
    else
      [top | rest]
    end
  end

  defp maybe_exact_schema(matches, _ranked), do: matches

  # The summary keeps only the fields needed for ranking. The action schema is
  # recovered by name from the registry, so search never copies domain data.
  defp action_schema(%{"action" => action}), do: action_schema_by_name(action)

  defp action_schema_by_name(action) do
    case Catalog.get(action) do
      {:ok, _adapter, tool} -> Schema.stringify(tool.input_schema)
      _ -> nil
    end
  end

  defp score(%Tool{} = tool, intent) do
    query = intent |> String.downcase() |> String.trim()
    terms = String.split(query, ~r/[^a-z0-9_]+/, trim: true)
    name_phrase = tool.name |> String.downcase() |> String.replace(~r/[._]+/, " ")
    haystack = String.downcase(Enum.join([tool.name, tool.title, tool.description], " "))

    exact =
      cond do
        name_phrase == query -> 200
        String.contains?(String.downcase(tool.name), query) -> 100
        true -> 0
      end

    Enum.reduce(terms, exact, fn term, total ->
      total + if(String.contains?(haystack, term), do: 10, else: 0)
    end)
  end

  defp area_matches?(_tool, nil), do: true

  defp area_matches?(%Tool{name: name}, area),
    do:
      String.starts_with?(name, area <> ".") or
        (area == "platform" and String.starts_with?(name, "projects."))

  defp public_action?(%Tool{name: name}),
    do: is_binary(name) and not String.starts_with?(name, "_")

  defp availability(principal, tool) do
    if Scope.allowed?(principal, tool), do: "available", else: "missing_scope"
  end

  defp missing_scope(_principal, _tool, ""), do: nil

  defp missing_scope(principal, tool, required) do
    if Scope.allowed?(principal, tool), do: nil, else: required
  end

  defp context_for(%Principal{scope_mode: :organization} = principal, args, organization) do
    case value(args, "project_ref") do
      project_ref when is_binary(project_ref) ->
        with {:ok, scope} <- Tenancy.resolve(principal, project_ref),
             {:ok, project} <-
               Ash.get(Alplus.Projects.Project, scope.project_id, authorize?: false) do
          {:ok, context_payload(principal, organization, project_summary(project), [], nil)}
        else
          _ -> {:error, Error.from(:not_found)}
        end

      nil ->
        list_organization_projects(principal, args, organization)

      _ ->
        {:error, Error.from({:invalid_argument, "project_ref"})}
    end
  end

  defp context_for(%Principal{project_id: project_id} = principal, args, organization)
       when is_binary(project_id) do
    project_ref = value(args, "project_ref") || project_id

    with {:ok, scope} <- Tenancy.resolve(principal, project_ref),
         {:ok, project} <- Ash.get(Alplus.Projects.Project, scope.project_id, authorize?: false) do
      summary = project_summary(project)
      {:ok, context_payload(principal, organization, summary, [summary], nil)}
    else
      _ -> {:error, Error.from(:not_found)}
    end
  end

  defp context_for(_principal, _args, _organization), do: {:error, Error.from(:not_found)}

  defp list_organization_projects(principal, args, organization) do
    query = value(args, "query")
    limit = value(args, "limit") || 20
    cursor = value(args, "cursor")

    cond do
      not is_nil(query) and (not is_binary(query) or String.trim(query) == "") ->
        {:error, Error.from({:invalid_argument, "query"})}

      not is_integer(limit) or limit < 1 or limit > 50 ->
        {:error, Error.from({:invalid_argument, "limit"})}

      not is_nil(cursor) and not is_binary(cursor) ->
        {:error, Error.from({:invalid_argument, "cursor"})}

      true ->
        filters = %{"query" => query || ""}

        with {:ok, offset} <- project_offset(principal, filters, cursor),
             {:ok, projects} <- organization_projects(principal) do
          matching = filter_projects(projects, query)
          page = matching |> Enum.drop(offset) |> Enum.take(limit)
          next_offset = offset + length(page)

          next_cursor =
            if next_offset < length(matching),
              do: Cursor.encode(principal, "context.projects", filters, next_offset),
              else: nil

          {:ok,
           context_payload(
             principal,
             organization,
             nil,
             Enum.map(page, &project_summary/1),
             next_cursor
           )}
        else
          {:error, reason} when reason in [:invalid_cursor, :cursor_expired] ->
            {:error, Error.from(reason)}

          _ ->
            {:error, Error.from(:not_found)}
        end
    end
  end

  defp organization_projects(principal) do
    with {:ok, scope} <-
           Alplus.Orgs.build_scope(
             Alplus.Scope.for_user(principal.user_id),
             principal.org_id
           ),
         {:ok, projects} <-
           Alplus.Projects.list_projects_for_org(principal.org_id, actor: scope) do
      {:ok, Enum.sort_by(projects, &{String.downcase(&1.name), &1.id})}
    end
  end

  defp filter_projects(projects, nil), do: projects

  defp filter_projects(projects, query) do
    query = query |> String.trim() |> String.downcase()

    Enum.filter(projects, fn project ->
      Enum.any?([project.name, project.public_token, project.id], fn value ->
        is_binary(value) and String.contains?(String.downcase(value), query)
      end)
    end)
  end

  defp project_offset(_principal, _filters, nil), do: {:ok, 0}

  defp project_offset(principal, filters, cursor) do
    case Cursor.decode(principal, "context.projects", filters, cursor) do
      {:ok, offset} when is_integer(offset) and offset >= 0 -> {:ok, offset}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_cursor}
    end
  end

  defp context_payload(principal, organization, project, projects, next_cursor) do
    %{
      "organization" => %{"id" => organization.id, "name" => to_string(organization.name)},
      "access_mode" => access_mode(principal.scopes),
      "project" => project,
      "projects" => projects,
      "next_cursor" => next_cursor,
      "scopes" => principal.scopes || [],
      "product_areas" => product_areas()
    }
  end

  defp project_summary(project) do
    %{
      "handle" => project.id,
      "project_ref" => project.public_token || project.id,
      "name" => project.name
    }
  end

  defp access_mode(scopes) when is_list(scopes) do
    if Enum.any?(scopes, &(is_binary(&1) and String.ends_with?(&1, ":write"))),
      do: "read_write",
      else: "read"
  end

  defp access_mode(_scopes), do: "read"

  defp value(args, key), do: Map.get(args, key) || Map.get(args, atom_key(key))

  defp atom_key(key) do
    try do
      String.to_existing_atom(key)
    rescue
      ArgumentError -> key
    end
  end

  defp product_areas, do: @areas
end
