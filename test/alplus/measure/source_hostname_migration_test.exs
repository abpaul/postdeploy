defmodule Alplus.Measure.SourceHostnameMigrationTest do
  use Alplus.DataCase, async: true

  @moduledoc """
  Verifies the SQL hostname contract used by
  `20260825120000_add_measure_source_hostname`.

  The migration is intentionally not rerun against the shared test schema;
  this query exercises the exact predicate used by its backfill and keeps the
  invalid legacy display-name examples from being normalized.
  """

  test "backfill predicate matches OriginAllowlist DNS labels" do
    pattern =
      "^[a-z0-9]([a-z0-9-]*[a-z0-9])?([.][a-z0-9]([a-z0-9-]*[a-z0-9])?)*$|^\\*[.][a-z0-9]([a-z0-9-]*[a-z0-9])?([.][a-z0-9]([a-z0-9-]*[a-z0-9])?)+$"

    values = [
      "example.com",
      "Example.COM",
      "localhost",
      "*.example.com",
      "foo_bar",
      "site@example.com",
      "example..com",
      "-example.com"
    ]

    %{rows: rows} =
      Alplus.Repo.query!(
        """
        SELECT value
        FROM unnest($1::text[]) AS candidates(value)
        WHERE octet_length(btrim(value)) BETWEEN 1 AND 255
          AND lower(btrim(value)) ~ $2
        -- Byte order, so the expected list does not depend on the database
        -- collation. A linguistic collation treats case as a minor
        -- difference and sorts "example.com" before "Example.COM".
        ORDER BY value COLLATE "C"
        """,
        [values, pattern]
      )

    assert rows == [["*.example.com"], ["Example.COM"], ["example.com"], ["localhost"]]
  end
end
