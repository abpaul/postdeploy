defmodule Alplus.Seo.McpAdapter do
  @moduledoc "Exposes the feature-gated SEO pilot configuration to MCP callers."

  @behaviour Alplus.Mcp.Adapter

  alias Alplus.Mcp.{Args, Error, Principal, Tenancy, ToolSpec}
  alias Alplus.Seo.{Feature, Profile, Refresher}

  @impl true
  def prefix, do: "seo"

  @impl true
  def tools do
    [
      ToolSpec.mutation_tool(
        "seo.create_profile",
        "Create an SEO profile",
        "Connect one Measure site to a Google country and language. The first collection starts now.",
        profile_input(),
        profile_output(),
        %{idempotentHint: true}
      ),
      ToolSpec.mutation_tool(
        "seo.add_competitor",
        "Add an SEO competitor",
        "Compare one domain with an SEO profile. A profile supports up to three competitors.",
        competitor_input(),
        competitor_output(),
        %{idempotentHint: true}
      ),
      ToolSpec.mutation_tool(
        "seo.refresh",
        "Refresh SEO data",
        "Collect current Google organic visibility for one configured SEO profile. The organization monthly collection allowance applies.",
        %{profile_handle: %{type: "string", minLength: 1}},
        %{
          type: "object",
          properties: %{refresh_handle: %{type: "string"}},
          required: ["refresh_handle"],
          additionalProperties: false
        },
        %{idempotentHint: true}
      )
    ]
  end

  @impl true
  def call(tool, args, %Principal{} = principal) do
    with {:ok, project_handle} <- Args.required_string(args, "project_handle"),
         {:ok, scope} <- Tenancy.resolve(principal, project_handle),
         true <- Feature.enabled?(scope),
         {:ok, result} <- dispatch(tool, args, scope) do
      {:ok, result}
    else
      false -> {:error, Error.from(:not_found)}
      {:error, reason} -> {:error, Error.from(reason)}
    end
  end

  defp dispatch("seo.create_profile", args, scope) do
    with {:ok, source_id} <- Args.required_string(args, "source_handle"),
         {:ok, target} <- Args.required_string(args, "target"),
         {:ok, profile} <-
           Alplus.Seo.create_profile(
             %{
               org_id: scope.org_id,
               project_id: scope.project_id,
               source_id: source_id,
               target: target,
               location_code: Args.value(args, "location_code"),
               language_code: Args.value(args, "language_code")
             },
             actor: scope
           ),
         {:ok, refresh} <- Refresher.queue(profile, :initial) do
      {:ok, %{profile: profile_payload(profile), refresh_handle: refresh.id}}
    end
  end

  defp dispatch("seo.add_competitor", args, scope) do
    with {:ok, profile} <- profile(args, scope),
         {:ok, target} <- Args.required_string(args, "target"),
         {:ok, competitor} <-
           Alplus.Seo.create_competitor(
             %{
               org_id: scope.org_id,
               project_id: scope.project_id,
               profile_id: profile.id,
               target: target
             },
             actor: scope
           ) do
      {:ok, %{competitor: %{handle: competitor.id, target: competitor.target}}}
    end
  end

  defp dispatch("seo.refresh", args, scope) do
    with {:ok, profile} <- profile(args, scope),
         {:ok, refresh} <- Refresher.queue(profile, :manual) do
      {:ok, %{refresh_handle: refresh.id}}
    end
  end

  defp dispatch(_, _args, _scope), do: {:error, :not_found}

  defp profile(args, scope) do
    with {:ok, id} <- Args.required_string(args, "profile_handle"),
         {:ok, profile} <- Ash.get(Profile, id, actor: scope) do
      {:ok, profile}
    else
      _ -> {:error, :not_found}
    end
  end

  defp profile_input do
    %{
      type: "object",
      properties: %{
        source_handle: %{type: "string", minLength: 1},
        target: %{type: "string", minLength: 1, maxLength: 255},
        location_code: %{type: "integer", minimum: 1},
        language_code: %{type: "string", pattern: "^[a-z]{2,3}(-[A-Z]{2})?$"}
      },
      required: ["source_handle", "target", "location_code", "language_code"],
      additionalProperties: false
    }
  end

  defp profile_output,
    do: %{
      type: "object",
      properties: %{profile: %{type: "object"}, refresh_handle: %{type: "string"}},
      required: ["profile", "refresh_handle"],
      additionalProperties: false
    }

  defp competitor_input,
    do: %{
      type: "object",
      properties: %{
        profile_handle: %{type: "string", minLength: 1},
        target: %{type: "string", minLength: 1, maxLength: 255}
      },
      required: ["profile_handle", "target"],
      additionalProperties: false
    }

  defp competitor_output,
    do: %{
      type: "object",
      properties: %{competitor: %{type: "object"}},
      required: ["competitor"],
      additionalProperties: false
    }

  defp profile_payload(profile),
    do: %{
      handle: profile.id,
      target: profile.target,
      location_code: profile.location_code,
      language_code: profile.language_code
    }
end
