defmodule Alplus.Id do
  @moduledoc """
  Prefixed UUIDv7 identifiers (ARCHITECTURE.md §5): `<prefix>_` + UUIDv7 rendered
  as a 26-character lowercase Crockford base32 string, e.g. `proj_01j2x3y4z5abcdefghjkmnpqrs`.

  Ported from `packages/core/src/id/id.ts` (`ID_PREFIXES`, `toCrockfordBase32`, `id/1`).
  This is the only id generator every Ash resource's primary key must use;
  never inline `Ash.UUID.generate/0` or a raw UUID for a resource id.

  Use as an `Ash.Type` on an attribute with a `prefix` constraint:

      attribute :id, Alplus.Id do
        constraints prefix: "user"
        public? true
        writable? false
        primary_key? true
        allow_nil? false
        default fn -> Alplus.Id.generate("user") end
      end
  """

  use Ash.Type, autogenerate_enabled?: true

  @crockford_alphabet ~c"0123456789abcdefghjkmnpqrstvwxyz"
  @encode_table @crockford_alphabet
                |> Enum.with_index()
                |> Map.new(fn {char, index} -> {index, char} end)
  @decode_table @crockford_alphabet
                |> Enum.with_index()
                |> Map.new(fn {char, index} -> {char, index} end)

  @body_length 26
  @format ~r/\A(?<prefix>[a-z]+)_(?<body>[0-9a-hjkmnp-tv-z]{26})\z/

  # Locked prefix registry, matches `packages/core/src/id/id.ts`'s `ID_PREFIXES`
  # and `docs/database/01-schema.md`. Keys are the domain concept; values are
  # the id prefix stored on the wire.
  @prefixes %{
    user: "user",
    membership: "mem",
    invitation: "inv",
    project: "proj",
    api_key: "key",
    issue: "iss",
    error_event: "err",
    release: "rel",
    release_artifact: "art",
    monitor: "mon",
    monitor_check: "chk",
    monitor_check_rollup: "roll",
    monitor_pause_interval: "mpau",
    incident: "inc",
    goal: "goal",
    custom_event_definition: "event",
    notification_channel: "chan",
    alert_rule: "rule",
    subscription: "sub",
    audit_log: "aud",
    feature_flag: "flag",
    feature_flag_override: "fovr",
    heartbeat_token: "hb",
    organization: "org",
    stripe_customer: "bcus",
    stripe_checkout_session: "bchk",
    invoice: "bill",
    usage_period: "usg",
    notification_delivery: "ndlv",
    request: "req",
    stripe_webhook_event: "whev",
    notify_job: "ntf",
    status_page: "sp",
    status_component: "scomp",
    status_incident: "sinc",
    status_incident_update: "siup",
    status_announcement: "sa",
    status_incident_draft: "sid",
    maintenance_window: "mw",
    waitlist_signup: "wl",
    environment: "env",
    project_domain: "pdom",
    content_page: "page",
    content_guide: "guide",
    content_integration: "integration",
    content_comparison: "comparison",
    content_seo_template: "seotmpl",
    # Added for issue #12 (crash-free sessions) -- no old-TS equivalent, so
    # picked fresh rather than mirroring `packages/core/src/id/id.ts`.
    session_rollup: "ssr",
    # ADR 0001 (unified telemetry Sources) -- no old-TS equivalent.
    source: "source",
    measure_dashboard_share: "mshare",
    issue_comment: "icm",
    issue_user_report: "iur",
    changelog_entry: "chg",
    changelog: "clog",
    changelog_revision: "crev",
    changelog_source_reference: "cref",
    changelog_activity_event: "cact",
    mcp_idempotency_record: "midm",
    public_page: "ppage",
    mcp_oauth_client: "mcocl",
    mcp_oauth_grant: "mcogr",
    mcp_oauth_authorization_code: "mcoac",
    mcp_oauth_access_token: "mcoat",
    mcp_oauth_refresh_token: "mcort",
    mcp_confirmation: "mconf",
    mail_delivery: "mail",
    seo_profile: "seop",
    seo_competitor: "seoc",
    seo_snapshot: "seos",
    seo_keyword: "seok",
    seo_page: "seopage",
    seo_refresh: "seor",
    # ADR 0007 (product analytics) -- no old-TS equivalent.
    product_event: "pev",
    product_funnel: "pfun",
    product_analytics_settings: "pana"
  }

  @doc "Returns the locked prefix registry, `concept => prefix`."
  @spec prefixes() :: %{atom() => String.t()}
  def prefixes, do: @prefixes

  @doc """
  Returns the id prefix for a registered concept.

  Raises on an unregistered concept: the registry is a closed, hand-maintained
  list, so an unknown key is a programmer error, not runtime input.
  """
  @spec prefix_for(atom()) :: String.t()
  def prefix_for(concept) when is_atom(concept) do
    Map.fetch!(@prefixes, concept)
  end

  @doc """
  Generates a new prefixed id, e.g. `generate("proj")` or `generate(:project)`
  -> `"proj_01j2x3y4z5abcdefghjkmnpqrs"`.
  """
  @spec generate(String.t() | atom()) :: String.t()
  def generate(prefix) when is_atom(prefix), do: generate(prefix_for(prefix))

  def generate(prefix) when is_binary(prefix) do
    prefix <> "_" <> (Ash.UUIDv7.bingenerate() |> to_crockford_base32())
  end

  @doc """
  Parses a prefixed id into `{prefix, uuid_bytes}`. Rejects a malformed
  length, invalid base32 characters, or a missing/malformed prefix separator.
  """
  @spec parse(String.t()) :: {:ok, String.t(), <<_::128>>} | :error
  def parse(value) when is_binary(value) do
    with %{"prefix" => prefix, "body" => body} <- Regex.named_captures(@format, value) || :error,
         {:ok, bytes} <- from_crockford_base32(body) do
      {:ok, prefix, bytes}
    else
      _ -> :error
    end
  end

  def parse(_), do: :error

  @doc "Validates that `value` is a well-formed id with the given `prefix`."
  @spec valid?(String.t(), String.t()) :: boolean()
  def valid?(value, prefix) when is_binary(value) and is_binary(prefix) do
    case parse(value) do
      {:ok, ^prefix, _bytes} -> true
      _ -> false
    end
  end

  # -- Crockford base32, 128 bits -> 26 lowercase chars, 5 bits at a time -----

  @spec to_crockford_base32(<<_::128>>) :: String.t()
  def to_crockford_base32(<<_::128>> = bytes) do
    bytes
    |> :binary.bin_to_list()
    |> Enum.reduce({0, 0, []}, fn byte, {bit_buffer, bit_count, out} ->
      bit_buffer = Bitwise.bor(Bitwise.bsl(bit_buffer, 8), byte)
      bit_count = bit_count + 8
      flush_full_groups(bit_buffer, bit_count, out)
    end)
    |> case do
      {bit_buffer, bit_count, out} when bit_count > 0 ->
        char =
          Map.fetch!(@encode_table, Bitwise.band(Bitwise.bsl(bit_buffer, 5 - bit_count), 0x1F))

        [char | out]

      {_bit_buffer, 0, out} ->
        out
    end
    |> Enum.reverse()
    |> List.to_string()
  end

  defp flush_full_groups(bit_buffer, bit_count, out) when bit_count >= 5 do
    bit_count = bit_count - 5
    char = Map.fetch!(@encode_table, Bitwise.band(Bitwise.bsr(bit_buffer, bit_count), 0x1F))
    flush_full_groups(bit_buffer, bit_count, [char | out])
  end

  defp flush_full_groups(bit_buffer, bit_count, out), do: {bit_buffer, bit_count, out}

  @spec from_crockford_base32(String.t()) :: {:ok, <<_::128>>} | :error
  defp from_crockford_base32(body) when byte_size(body) == @body_length do
    body
    |> String.to_charlist()
    |> Enum.reduce_while({0, 0, []}, fn char, {bit_buffer, bit_count, out} ->
      case Map.fetch(@decode_table, char) do
        {:ok, value} ->
          bit_buffer = Bitwise.bor(Bitwise.bsl(bit_buffer, 5), value)
          bit_count = bit_count + 5
          {bit_buffer, bit_count, out} = drain_full_bytes(bit_buffer, bit_count, out)
          {:cont, {bit_buffer, bit_count, out}}

        :error ->
          {:halt, :error}
      end
    end)
    |> case do
      :error ->
        :error

      {_bit_buffer, _bit_count, out} ->
        bytes = out |> Enum.reverse() |> :binary.list_to_bin()
        # 26 chars * 5 bits = 130 bits; the last 2 bits are padding from encode's
        # `padEnd`/final short group and are discarded, leaving the 128-bit body.
        <<uuid_bytes::binary-size(16), _rest::binary>> = bytes
        {:ok, uuid_bytes}
    end
  end

  defp from_crockford_base32(_body), do: :error

  defp drain_full_bytes(bit_buffer, bit_count, out) when bit_count >= 8 do
    bit_count = bit_count - 8
    byte = Bitwise.band(Bitwise.bsr(bit_buffer, bit_count), 0xFF)
    drain_full_bytes(bit_buffer, bit_count, [byte | out])
  end

  defp drain_full_bytes(bit_buffer, bit_count, out), do: {bit_buffer, bit_count, out}

  # -- Ash.Type -----------------------------------------------------------

  @impl true
  def storage_type(_constraints), do: :text

  @impl true
  def constraints,
    do: [
      prefix: [
        type: :string,
        required: true,
        doc: "The required id prefix for this attribute, e.g. \"user\" or \"proj\"."
      ]
    ]

  @impl true
  def generator(constraints) do
    prefix = Keyword.fetch!(constraints, :prefix)
    StreamData.repeatedly(fn -> generate(prefix) end)
  end

  @impl true
  def matches_type?(value, constraints) do
    case cast_input(value, constraints) do
      {:ok, _} -> true
      _ -> false
    end
  end

  @impl true
  def cast_input(nil, _constraints), do: {:ok, nil}

  def cast_input(value, constraints) when is_binary(value) do
    prefix = Keyword.fetch!(constraints, :prefix)

    case parse(value) do
      {:ok, ^prefix, _bytes} -> {:ok, value}
      _ -> {:error, message: "must be a valid #{prefix}_ id"}
    end
  end

  def cast_input(_value, _constraints), do: :error

  @impl true
  def cast_atomic(new_value, _constraints), do: {:atomic, new_value}

  @impl true
  def cast_stored(nil, _constraints), do: {:ok, nil}
  def cast_stored(value, constraints), do: cast_input(value, constraints)

  @impl true
  def dump_to_native(nil, _constraints), do: {:ok, nil}
  def dump_to_native(value, _constraints) when is_binary(value), do: {:ok, value}

  @impl true
  def dump_to_embedded(value, constraints), do: cast_input(value, constraints)
end
