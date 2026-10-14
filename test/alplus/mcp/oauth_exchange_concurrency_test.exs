defmodule Alplus.Mcp.OAuthExchangeConcurrencyTest do
  @moduledoc """
  Authorization-code exchange under real concurrency, through
  `Alplus.Mcp.OAuth.exchange_code/1`.

  Warning: these tests commit rows. Read `Alplus.ConcurrencyCase` first.
  """

  # Not async: these tests run outside the Ecto sandbox on real connections.
  use Alplus.ConcurrencyCase, async: false

  alias Alplus.Mcp
  alias Alplus.Mcp.OAuth
  alias Alplus.Scope
  alias Alplus.Security.BearerToken

  @lock_wait_timeout_ms 20_000
  @client_id "https://client.example/oauth-exchange-concurrency.json"
  @redirect_uri "https://client.example/oauth/callback"
  @verifier "a-verifier-that-is-long-enough-for-pkce-s256-testing"
  @state "oauth-exchange-concurrency-state"

  test "allows only one of two concurrent exchanges of the same authorization code" do
    scope = scope_fixture()
    {org, owner_scope} = org_fixture(scope)
    delete_after_test([org.id], [scope.user_id])

    project = project_fixture(owner_scope, org)
    actor = Scope.put_project(owner_scope, project.id)
    cache_client!()

    {:ok, request} = OAuth.validate_authorization_request(authorization_params())
    assert {:error, :invalid_request} = OAuth.authorize(request, actor, [])
    assert {:error, :invalid_request} = OAuth.authorize(request, actor, ["monitor:write"])
    {:ok, callback} = OAuth.authorize(request, actor, String.split(request.scope))
    code = callback_code(callback)
    grant_id = grant_id_for_code(code)
    params = token_params(code)

    results =
      race_for_authorization_code(BearerToken.short_prefix(code), fn ->
        OAuth.exchange_code(params)
      end)

    {successes, failures} = Enum.split_with(results, &match?({:ok, _}, &1))

    assert length(successes) == 1
    assert length(failures) == 1
    assert {:ok, %{"access_token" => access_token}} = hd(successes)
    assert is_binary(access_token) and byte_size(access_token) > 0
    assert {:error, :invalid_grant} = hd(failures)
    assert access_token_count(grant_id) == 1
  end

  defp cache_client! do
    now = DateTime.utc_now()

    {:ok, _client} =
      Mcp.cache_oauth_client(
        %{
          issuer: OAuth.issuer(),
          client_id: @client_id,
          client_name: "OAuth exchange concurrency client",
          redirect_uris: [@redirect_uri],
          fetched_at: now,
          expires_at: DateTime.add(now, 3600, :second)
        },
        authorize?: false
      )
  end

  defp authorization_params do
    %{
      "response_type" => "code",
      "client_id" => @client_id,
      "redirect_uri" => @redirect_uri,
      "scope" => "projects:read",
      "state" => @state,
      "resource" => OAuth.resource_uri(),
      "code_challenge" => code_challenge(@verifier),
      "code_challenge_method" => "S256"
    }
  end

  defp token_params(code) do
    %{
      "grant_type" => "authorization_code",
      "code" => code,
      "code_verifier" => @verifier,
      "redirect_uri" => @redirect_uri,
      "client_id" => @client_id,
      "resource" => OAuth.resource_uri()
    }
  end

  defp callback_code(callback_url) do
    query = callback_url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    assert %{"code" => code, "state" => @state} = query
    code
  end

  defp grant_id_for_code(code) do
    %{rows: [[grant_id]]} =
      Alplus.Repo.query!(
        "SELECT grant_id FROM mcp_oauth_authorization_codes WHERE code_prefix = $1",
        [BearerToken.short_prefix(code)]
      )

    grant_id
  end

  defp access_token_count(grant_id) do
    %{rows: [[count]]} =
      Alplus.Repo.query!("SELECT count(*) FROM mcp_oauth_access_tokens WHERE grant_id = $1", [
        grant_id
      ])

    count
  end

  defp code_challenge(verifier) do
    :crypto.hash(:sha256, verifier)
    |> Base.url_encode64(padding: false)
  end

  # Holds the authorization-code row until both exchangers are parked on that
  # same lock inside their own transactions. A start-together barrier is not
  # enough: one caller can finish before the other opens a transaction.
  defp race_for_authorization_code(code_prefix, fun) do
    parent = self()
    holder = start_code_lock_holder(code_prefix)

    tasks =
      Enum.map(1..2, fn _index ->
        Task.async(fn ->
          checkout_committing_connection()
          send(parent, {:racer_ready, backend_pid()})

          receive do
            :go -> :ok
          after
            @lock_wait_timeout_ms -> raise "the race never started"
          end

          fun.()
        end)
      end)

    backend_pids = Enum.map(tasks, fn _task -> await_ready() end)
    Enum.each(tasks, fn task -> send(task.pid, :go) end)
    await_all_blocked_on_lock(backend_pids)
    release_lock_holder(holder)
    Task.await_many(tasks, 30_000)
  end

  defp start_code_lock_holder(code_prefix) do
    parent = self()

    pid =
      spawn_link(fn ->
        checkout_committing_connection()

        Alplus.Repo.transaction(fn ->
          Alplus.Repo.query!(
            """
            SELECT id
            FROM mcp_oauth_authorization_codes
            WHERE code_prefix = $1
            FOR UPDATE
            """,
            [code_prefix]
          )

          send(parent, {:lock_held, self()})

          receive do
            :release -> :ok
          after
            @lock_wait_timeout_ms -> :ok
          end
        end)
      end)

    receive do
      {:lock_held, ^pid} -> pid
    after
      @lock_wait_timeout_ms -> raise "the lock holder never took the authorization code row lock"
    end
  end

  defp release_lock_holder(pid) do
    reference = Process.monitor(pid)
    send(pid, :release)

    receive do
      {:DOWN, ^reference, :process, ^pid, _reason} -> :ok
    after
      @lock_wait_timeout_ms ->
        raise "the lock holder never released the authorization code row lock"
    end
  end

  defp await_all_blocked_on_lock(backend_pids) do
    await_all_blocked_on_lock(
      backend_pids,
      System.monotonic_time(:millisecond) + @lock_wait_timeout_ms
    )
  end

  defp await_all_blocked_on_lock(backend_pids, deadline) do
    wanted = length(backend_pids)
    blocked = blocked_count(backend_pids)

    cond do
      blocked == wanted ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        raise "only #{blocked} of #{wanted} racers parked on the authorization code row lock"

      true ->
        Process.sleep(10)
        await_all_blocked_on_lock(backend_pids, deadline)
    end
  end

  defp blocked_count(backend_pids) do
    %{rows: [[count]]} =
      Alplus.Repo.query!(
        """
        SELECT count(*)
        FROM pg_stat_activity
        WHERE pid = ANY($1::int[]) AND wait_event_type = 'Lock'
        """,
        [backend_pids]
      )

    count
  end

  defp backend_pid do
    %{rows: [[pid]]} = Alplus.Repo.query!("SELECT pg_backend_pid()", [])
    pid
  end

  defp await_ready do
    receive do
      {:racer_ready, backend_pid} -> backend_pid
    after
      @lock_wait_timeout_ms -> raise "a racing process never checked out its connection"
    end
  end
end
