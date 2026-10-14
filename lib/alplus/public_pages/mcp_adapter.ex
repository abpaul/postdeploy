defmodule Alplus.PublicPages.McpAdapter do
  @moduledoc "Exposes the project-scoped Public identity through the shared MCP catalog."

  @behaviour Alplus.Mcp.Adapter

  alias Alplus.Mcp.{Args, Error, Principal, Tenancy, ToolSpec}

  import Alplus.Mcp.ToolSpec, only: [nullable_string: 0, object_schema: 1, string: 2]

  @impl true
  def prefix, do: "public"

  @impl true
  def tools do
    [
      read_tool(
        "public.get_identity",
        "Get Public identity",
        "Read the singleton Public identity for a project, including publication state and safe branding fields.",
        %{},
        %{identity: identity_schema()}
      ),
      read_tool(
        "public.list_aliases",
        "List Public aliases",
        "List retained public Status aliases for a project. Private tokens and internal records are excluded.",
        %{},
        %{aliases: %{type: "array"}}
      ),
      read_tool(
        "public.get_links",
        "Get Public links",
        "Return canonical public Status, history, feed, embed, and changelog links for the singleton identity.",
        %{},
        %{links: %{type: "object"}}
      ),
      customer_mutation_tool(
        "public.update_identity",
        "Update Public identity",
        "Update the project Public title, slug, or logo reference. Existing aliases and cache behavior are preserved.",
        %{title: string(1, 200), public_slug: string(1, 200), logo_url: nullable_string()},
        [],
        %{identity: identity_schema()}
      ),
      customer_mutation_tool(
        "public.publish",
        "Publish Public identity",
        "Publish the singleton Public identity so customers can read its Status surfaces. This is customer-visible.",
        %{},
        [],
        %{identity: identity_schema()}
      ),
      customer_mutation_tool(
        "public.unpublish",
        "Unpublish Public identity",
        "Unpublish the singleton Public identity. Existing aliases remain retained and customer pages become unavailable.",
        %{},
        [],
        %{identity: identity_schema()}
      )
    ]
    |> Enum.sort_by(& &1.name)
  end

  @impl true
  def call(tool, args, %Principal{} = principal) when is_binary(tool) and is_map(args) do
    with {:ok, project_handle} <- Args.required_string(args, "project_handle"),
         {:ok, scope} <- Tenancy.resolve(principal, project_handle),
         {:ok, result} <- dispatch(tool, args, scope) do
      {:ok, result}
    else
      {:error, reason} -> {:error, map_error(reason)}
    end
  end

  def call(_tool, _args, _principal), do: {:error, Error.from(:invalid_argument)}

  defp dispatch("public.get_identity", _args, scope) do
    with {:ok, identity} <- Alplus.PublicPages.get_for_scope(scope) do
      {:ok, %{identity: identity_payload(identity)}}
    end
  end

  defp dispatch("public.list_aliases", _args, scope) do
    with {:ok, aliases} <- Alplus.PublicPages.aliases_for_project(scope, scope.project_id) do
      {:ok, %{aliases: Enum.map(aliases, &alias_payload/1)}}
    end
  end

  defp dispatch("public.get_links", _args, scope) do
    with {:ok, identity} <- Alplus.PublicPages.get_for_scope(scope) do
      slug = identity.public_slug
      base = "/status/#{slug}"

      {:ok,
       %{
         links: %{
           status: base,
           history: base <> "/history",
           feed: base <> "/feed.xml",
           embed: base <> "/embed",
           embed_json: base <> "/embed.json",
           changelog: base <> "/changelog",
           changelog_feed: base <> "/changelog.rss",
           changelog_json: base <> "/changelog.json"
         }
       }}
    end
  end

  defp dispatch("public.update_identity", args, scope) do
    with {:ok, identity} <- Alplus.PublicPages.get_for_scope(scope),
         attrs <- present_attrs(args, [:title, :public_slug, :logo_url]),
         {:ok, identity} <- Alplus.PublicPages.update(scope, identity, attrs) do
      {:ok, %{identity: identity_payload(identity)}}
    end
  end

  defp dispatch("public.publish", _args, scope) do
    with {:ok, identity} <- Alplus.PublicPages.get_for_scope(scope),
         {:ok, identity} <- Alplus.PublicPages.publish(scope, identity) do
      {:ok, %{identity: identity_payload(identity)}}
    end
  end

  defp dispatch("public.unpublish", _args, scope) do
    with {:ok, identity} <- Alplus.PublicPages.get_for_scope(scope),
         {:ok, identity} <- Alplus.PublicPages.unpublish(scope, identity) do
      {:ok, %{identity: identity_payload(identity)}}
    end
  end

  defp identity_payload(identity) do
    %{
      handle: identity.id,
      title: identity.title,
      public_slug: identity.public_slug,
      logo_url: identity.logo_url,
      published: not is_nil(identity.published_at),
      published_at: datetime(identity.published_at)
    }
  end

  defp alias_payload(alias_record) do
    %{handle: alias_record.id, public_slug: alias_record.public_slug, kind: alias_record.kind}
  end

  defp present_attrs(args, keys) do
    Enum.reduce(keys, %{}, fn key, acc ->
      value = Args.value(args, Atom.to_string(key))
      if is_nil(value), do: acc, else: Map.put(acc, key, value)
    end)
  end

  defp read_tool(name, title, description, properties, output),
    do:
      ToolSpec.read_tool(
        name,
        title,
        description,
        schema(properties, [], false),
        object_schema(output)
      )

  defp customer_mutation_tool(name, title, description, properties, required, output),
    do:
      ToolSpec.mutation_tool(
        name,
        title,
        description,
        schema(properties, required, true),
        object_schema(output),
        %{idempotentHint: true, destructiveHint: false, openWorldHint: true}
      )

  defp schema(properties, required, mutation?) do
    properties =
      properties |> Map.put(:project_handle, string(1, 200)) |> maybe_idempotency(mutation?)

    ToolSpec.strict_object(properties, [
      "project_handle" | if(mutation?, do: ["idempotency_key" | required], else: required)
    ])
  end

  defp maybe_idempotency(properties, true),
    do: Map.put(properties, :idempotency_key, string(1, 200))

  defp maybe_idempotency(properties, false), do: properties

  defp identity_schema do
    object_schema(%{
      handle: string(1, 200),
      title: string(1, 200),
      public_slug: string(1, 200),
      logo_url: nullable_string(),
      published: %{type: "boolean"},
      published_at: nullable_string()
    })
  end

  defp datetime(nil), do: nil
  defp datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp datetime(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp datetime(value), do: value

  defp map_error(:legacy_slug_collision),
    do: Error.new(:conflict, "The requested public address is unavailable", %{})

  defp map_error(reason), do: Error.from(reason)
end
