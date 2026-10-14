defmodule Alplus.Mcp.ScopeTest do
  use ExUnit.Case, async: true

  alias Alplus.Id
  alias Alplus.Mcp.{Catalog, Dispatch, OAuthGrant, Principal, Scope, Tool}

  @vocabulary MapSet.new([
                "analytics:read",
                "analytics:write",
                "changelog:read",
                "changelog:write",
                "errors:read",
                "errors:write",
                "monitor:read",
                "monitor:write",
                "projects:read",
                "projects:write",
                "status:read",
                "status:write"
              ])

  # Independent of Alplus.Mcp.Scope: prefix + existing requires_access.
  # A new catalog prefix or an unmapped access fails Map.fetch!/2.
  @scope_by_prefix %{
    "analytics" => %{read: "analytics:read", read_write: "analytics:write"},
    "changelog" => %{read: "changelog:read", read_write: "changelog:write"},
    "measure" => %{read: "analytics:read", read_write: "analytics:write"},
    "monitor" => %{read: "monitor:read", read_write: "monitor:write"},
    "observe" => %{read: "errors:read", read_write: "errors:write"},
    "projects" => %{read: "projects:read", read_write: "projects:write"},
    "seo" => %{read: "analytics:read", read_write: "analytics:write"},
    "public" => %{read: "status:read", read_write: "status:write"},
    "status" => %{read: "status:read", read_write: "status:write"}
  }

  describe "vocabulary" do
    test "exposes exactly the twelve OAuth scopes" do
      assert MapSet.new(Scope.all()) == @vocabulary
      assert length(Scope.all()) == MapSet.size(@vocabulary)
    end
  end

  describe "catalog mapping" do
    test "every live catalog tool maps to one vocabulary scope from prefix and access" do
      catalog = Catalog.all()
      assert catalog != []

      for %Tool{} = tool <- catalog do
        expected = expected_scope(tool)
        assert MapSet.member?(@vocabulary, expected)
        assert Scope.required(tool) == expected
        assert Scope.required(tool.name) == expected
      end

      mapped = MapSet.new(catalog, &Scope.required/1)
      assert MapSet.subset?(mapped, @vocabulary)
    end
  end

  describe "oauth principals" do
    test "carry grant_id and scopes without a static credential identity" do
      scopes = ["projects:read"]
      principal = oauth_principal(scopes)
      keys = principal_keys(principal)

      assert %Principal{source: :oauth, scopes: ^scopes, grant_id: grant_id} = principal
      assert String.starts_with?(grant_id, "mcogr_")
      assert :grant_id in keys
      refute :credential_id in keys
    end

    test "an exact scope is allowed and lists only the tools that require it" do
      catalog = Catalog.all()
      by_scope = Enum.group_by(catalog, &expected_scope/1)

      for {scope, tools} <- by_scope do
        principal = oauth_principal([scope])
        expected_names = names(tools)

        assert names(Catalog.tools(principal)) == expected_names
        assert names(Dispatch.tools(principal)) == expected_names

        for tool <- tools do
          assert Scope.allowed?(principal, tool)
          assert Scope.allowed?(principal, tool.name)
        end
      end

      for scope <- @vocabulary, not Map.has_key?(by_scope, scope) do
        principal = oauth_principal([scope])
        assert Catalog.tools(principal) == []
        assert Dispatch.tools(principal) == []
      end
    end

    test "every other scope is denied and write does not imply read" do
      catalog = Catalog.all()

      for tool <- catalog do
        required = expected_scope(tool)
        others = @vocabulary |> MapSet.delete(required) |> MapSet.to_list()
        widened = oauth_principal(others)

        refute Scope.allowed?(widened, tool)
        refute Scope.allowed?(widened, tool.name)
        refute MapSet.member?(names(Catalog.tools(widened)), tool.name)
        refute MapSet.member?(names(Dispatch.tools(widened)), tool.name)

        for other <- others do
          principal = oauth_principal([other])
          refute Scope.allowed?(principal, tool)
          refute MapSet.member?(names(Catalog.tools(principal)), tool.name)
        end
      end
    end

    test "an oauth principal with no scopes is denied every catalog tool" do
      principal = oauth_principal([])
      assert Catalog.tools(principal) == []
      assert Dispatch.tools(principal) == []

      for tool <- Catalog.all() do
        refute Scope.allowed?(principal, tool)
      end
    end
  end

  describe "session principals" do
    test "retain read and read_write listing rules and ignore OAuth scopes" do
      catalog = Catalog.all()
      read_names = catalog |> Enum.filter(&(&1.requires_access == :read)) |> names()
      all_names = names(catalog)

      member = session_principal("member")
      owner = session_principal("owner")
      admin = session_principal("admin")

      assert member.source == :session
      assert member.scopes == nil
      assert member.grant_id == nil
      assert member.access == :read
      assert owner.access == :read_write
      assert admin.access == :read_write
      refute :credential_id in principal_keys(member)
      refute :credential_id in principal_keys(owner)

      assert names(Catalog.tools(member)) == read_names
      assert names(Dispatch.tools(member)) == read_names
      assert names(Catalog.tools(owner)) == all_names
      assert names(Dispatch.tools(owner)) == all_names
      assert names(Catalog.tools(admin)) == all_names
      assert names(Dispatch.tools(admin)) == all_names

      for tool <- catalog do
        assert Scope.allowed?(owner, tool)
        assert Scope.allowed?(admin, tool)

        if tool.requires_access == :read do
          assert Scope.allowed?(member, tool)
        else
          refute Scope.allowed?(member, tool)
        end
      end
    end
  end

  defp expected_scope(%Tool{name: name, requires_access: access}) do
    prefix = name |> String.split(".", parts: 2) |> hd()
    @scope_by_prefix |> Map.fetch!(prefix) |> Map.fetch!(access)
  end

  defp oauth_principal(scopes) do
    Principal.from_oauth(
      %OAuthGrant{
        id: Id.generate(:mcp_oauth_grant),
        org_id: Id.generate(:organization),
        project_id: Id.generate(:project),
        user_id: Id.generate(:user),
        resource: Alplus.Mcp.OAuth.resource_uri()
      },
      scopes
    )
  end

  defp session_principal(role) do
    %Alplus.Scope{
      user_id: Id.generate(:user),
      org_id: Id.generate(:organization),
      project_id: Id.generate(:project),
      role: role
    }
    |> Principal.from_session()
  end

  defp principal_keys(%Principal{} = principal) do
    principal |> Map.from_struct() |> Map.keys()
  end

  defp names(tools), do: MapSet.new(tools, & &1.name)
end
