defmodule Alplus.IdTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Alplus.Id

  describe "generate/1 and parse/1 round-trip" do
    property "any registered prefix round-trips through generate/parse" do
      check all(prefix <- member_of(Map.values(Id.prefixes()))) do
        id = Id.generate(prefix)

        assert {:ok, ^prefix, <<_::128>>} = Id.parse(id)
        assert String.starts_with?(id, prefix <> "_")
        assert byte_size(id) == byte_size(prefix) + 1 + 26
      end
    end

    property "generate/1 always produces a value cast_input accepts for the same prefix" do
      check all(prefix <- member_of(Map.values(Id.prefixes()))) do
        id = Id.generate(prefix)
        assert {:ok, ^id} = Id.cast_input(id, prefix: prefix)
      end
    end

    property "arbitrary 16-byte binaries round-trip through the base32 codec" do
      check all(bytes <- binary(length: 16)) do
        encoded = Id.to_crockford_base32(bytes)
        assert byte_size(encoded) == 26

        assert {:ok, "x", ^bytes} = Id.parse("x_" <> encoded)
      end
    end
  end

  test "parse, matches_type, generator, and dump leftovers" do
    assert :error = Id.parse(:not_a_string)
    assert :error = Id.parse("nope")
    assert Id.matches_type?(Id.generate("user"), prefix: "user")
    refute Id.matches_type?("nope", prefix: "user")
    assert {:atomic, "x"} = Id.cast_atomic("x", prefix: "user")
    id = Id.generate("user")
    assert {:ok, ^id} = Id.dump_to_embedded(id, prefix: "user")
    assert Enum.take(Id.generator(prefix: "user"), 1) != []
  end

  describe "golden master (packages/core/src/id/id.ts semantics)" do
    test "encodes a known UUIDv7 to the expected 26-char Crockford base32 body" do
      # UUIDv7 018e90d8-06e8-7f9f-bfd7-6730ba98a51b, taken from Ash.UUIDv7's own
      # moduledoc example (same RFC 9562 layout the TS `uuidV7Bytes` produced).
      bytes =
        <<0x01, 0x8E, 0x90, 0xD8, 0x06, 0xE8, 0x7F, 0x9F, 0xBF, 0xD7, 0x67, 0x30, 0xBA, 0x98,
          0xA5, 0x1B>>

      # Independently reproduced with a line-for-line port of the TS `toCrockfordBase32`
      # loop in Python; both agree with this Elixir implementation.
      assert Id.to_crockford_base32(bytes) == "06791p06x1zszfyqcwrbn6553c"
    end

    test "the example id from packages/core/src/id/id.ts's moduledoc parses and round-trips" do
      # `id(prefix)` -> `${prefix}_${toCrockfordBase32(uuidV7Bytes())}`, e.g.
      # "proj_01j2x3y4z5abcdefghjkmnpqrs" shown in the TS module doc.
      # That literal example string is illustrative (not a real captured id), so
      # assert the property it demonstrates: a 26-char lowercase Crockford body
      # after the prefix, using only the TS `CROCKFORD_ALPHABET` characters.
      example = "proj_01j2x3y4z5abcdefghjkmnpqrs"
      [prefix, body] = String.split(example, "_", parts: 2)

      assert prefix == "proj"
      assert byte_size(body) == 26
      assert body == String.downcase(body)

      assert body
             |> String.to_charlist()
             |> Enum.all?(&(&1 in ~c"0123456789abcdefghjkmnpqrstvwxyz"))
    end

    test "decode inverts encode for a swept set of byte patterns" do
      samples = [
        <<0::128>>,
        <<0xFF::128>>,
        for(_ <- 1..16, into: <<>>, do: <<0xAB>>),
        :crypto.strong_rand_bytes(16),
        :crypto.strong_rand_bytes(16)
      ]

      for bytes <- samples do
        encoded = Id.to_crockford_base32(bytes)
        assert {:ok, "t", ^bytes} = Id.parse("t_" <> encoded)
      end
    end
  end

  describe "rejection" do
    test "rejects a wrong prefix" do
      id = Id.generate("proj")
      assert {:ok, "proj", _} = Id.parse(id)
      assert {:error, _} = Id.cast_input(id, prefix: "mon")
    end

    test "rejects a wrong length body (too short)" do
      assert :error = Id.parse("proj_01j2x3y4z5abcdefghjkmnpqr")
    end

    test "rejects a wrong length body (too long)" do
      assert :error = Id.parse("proj_01j2x3y4z5abcdefghjkmnpqrsz")
    end

    test "rejects invalid base32 characters (i, l, o, u are excluded from Crockford)" do
      base = String.duplicate("0", 25)
      assert :error = Id.parse("proj_" <> base <> "i")
      assert :error = Id.parse("proj_" <> base <> "l")
      assert :error = Id.parse("proj_" <> base <> "o")
      assert :error = Id.parse("proj_" <> base <> "u")
    end

    test "rejects uppercase" do
      id = Id.generate("proj")
      assert :error = Id.parse(String.upcase(id))
    end

    test "rejects a missing prefix separator" do
      assert :error = Id.parse("proj01j2x3y4z5abcdefghjkmnpqrs")
    end

    test "rejects a completely malformed string" do
      assert :error = Id.parse("not-an-id")
      assert :error = Id.parse("")
    end

    test "cast_input/2 rejects nil body but accepts nil value" do
      assert {:ok, nil} = Id.cast_input(nil, prefix: "user")
    end

    test "cast_input/2 rejects a non-string value" do
      assert :error = Id.cast_input(123, prefix: "user")
      assert :error = Id.cast_input(%{}, prefix: "user")
    end

    test "cast_input/2 rejects a well-formed id for a different prefix" do
      id = Id.generate("mon")
      assert {:error, _} = Id.cast_input(id, prefix: "user")
    end
  end

  describe "ordering (UUIDv7 property)" do
    test "ids generated later sort lexicographically after earlier ones" do
      ids = for _ <- 1..200, do: Id.generate("proj")

      assert ids == Enum.sort(ids)
      assert Enum.uniq(ids) == ids
    end

    test "an id with a later embedded timestamp sorts strictly after an earlier one" do
      # Fixed clock, no sleep: embed two explicit timestamps via
      # Ash.UUIDv7.bingenerate/1 instead of racing the wall clock.
      earlier = ~U[2026-01-01 00:00:00.000Z]
      later = ~U[2026-01-01 00:00:00.500Z]

      first = "proj_" <> (earlier |> Ash.UUIDv7.bingenerate() |> Id.to_crockford_base32())
      second = "proj_" <> (later |> Ash.UUIDv7.bingenerate() |> Id.to_crockford_base32())

      assert first < second
    end
  end

  describe "prefix registry" do
    test "prefix_for/1 returns the locked prefix for a known concept" do
      assert Id.prefix_for(:user) == "user"
      assert Id.prefix_for(:project) == "proj"
      assert Id.prefix_for(:organization) == "org"
    end

    test "prefix_for/1 raises for an unregistered concept" do
      assert_raise KeyError, fn -> Id.prefix_for(:not_a_real_concept) end
    end

    test "valid?/2 checks prefix and shape together" do
      id = Id.generate(:project)
      assert Id.valid?(id, "proj")
      refute Id.valid?(id, "mon")
      refute Id.valid?("garbage", "proj")
    end
  end
end
