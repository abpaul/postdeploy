defmodule Alplus.Content.Comparison do
  @moduledoc """
  One `/alternatives/<slug>` competitor comparison page (ARCHITECTURE.md §3,
  §9). Public, not tenant-owned — no `org_id`.

  Ported from `workers/www/site/lib/competitors.ts` (`Competitor`). PostDeploy's own
  numbers are read from `Alplus.Billing.Package` at render time, never
  duplicated onto a row here (competitors.ts's own rule, `us` is omittable
  for that reason).
  """

  use Ash.Resource,
    otp_app: :alplus,
    domain: Alplus.Content,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "content_comparisons"
    repo Alplus.Repo

    custom_statements do
      statement :title_length_check do
        up "ALTER TABLE content_comparisons ADD CONSTRAINT content_comparisons_title_length_check CHECK (octet_length(title) <= 300)"

        down "ALTER TABLE content_comparisons DROP CONSTRAINT content_comparisons_title_length_check"
      end

      statement :meta_description_length_check do
        up "ALTER TABLE content_comparisons ADD CONSTRAINT content_comparisons_meta_description_length_check CHECK (octet_length(meta_description) <= 500)"

        down "ALTER TABLE content_comparisons DROP CONSTRAINT content_comparisons_meta_description_length_check"
      end

      statement :summary_length_check do
        up "ALTER TABLE content_comparisons ADD CONSTRAINT content_comparisons_summary_length_check CHECK (octet_length(summary) <= 500)"

        down "ALTER TABLE content_comparisons DROP CONSTRAINT content_comparisons_summary_length_check"
      end

      statement :competitor_name_length_check do
        up "ALTER TABLE content_comparisons ADD CONSTRAINT content_comparisons_competitor_name_length_check CHECK (octet_length(competitor_name) <= 200)"

        down "ALTER TABLE content_comparisons DROP CONSTRAINT content_comparisons_competitor_name_length_check"
      end

      statement :competitor_homepage_length_check do
        up "ALTER TABLE content_comparisons ADD CONSTRAINT content_comparisons_competitor_homepage_length_check CHECK (octet_length(competitor_homepage) <= 500)"

        down "ALTER TABLE content_comparisons DROP CONSTRAINT content_comparisons_competitor_homepage_length_check"
      end

      statement :positioning_length_check do
        up "ALTER TABLE content_comparisons ADD CONSTRAINT content_comparisons_positioning_length_check CHECK (octet_length(positioning) <= 1000)"

        down "ALTER TABLE content_comparisons DROP CONSTRAINT content_comparisons_positioning_length_check"
      end

      statement :tldr_length_check do
        up "ALTER TABLE content_comparisons ADD CONSTRAINT content_comparisons_tldr_length_check CHECK (octet_length(tldr) <= 2000)"

        down "ALTER TABLE content_comparisons DROP CONSTRAINT content_comparisons_tldr_length_check"
      end

      statement :body_sections_length_check do
        up "ALTER TABLE content_comparisons ADD CONSTRAINT content_comparisons_body_sections_length_check CHECK (octet_length(body_sections::text) <= 100000)"

        down "ALTER TABLE content_comparisons DROP CONSTRAINT content_comparisons_body_sections_length_check"
      end

      statement :why_looking_length_check do
        up "ALTER TABLE content_comparisons ADD CONSTRAINT content_comparisons_why_looking_length_check CHECK (octet_length(why_looking::text) <= 20000)"

        down "ALTER TABLE content_comparisons DROP CONSTRAINT content_comparisons_why_looking_length_check"
      end

      statement :free_tier_rows_length_check do
        up "ALTER TABLE content_comparisons ADD CONSTRAINT content_comparisons_free_tier_rows_length_check CHECK (octet_length(free_tier_rows::text) <= 20000)"

        down "ALTER TABLE content_comparisons DROP CONSTRAINT content_comparisons_free_tier_rows_length_check"
      end

      statement :they_do_better_length_check do
        up "ALTER TABLE content_comparisons ADD CONSTRAINT content_comparisons_they_do_better_length_check CHECK (octet_length(they_do_better::text) <= 30000)"

        down "ALTER TABLE content_comparisons DROP CONSTRAINT content_comparisons_they_do_better_length_check"
      end

      statement :we_do_better_length_check do
        up "ALTER TABLE content_comparisons ADD CONSTRAINT content_comparisons_we_do_better_length_check CHECK (octet_length(we_do_better::text) <= 30000)"

        down "ALTER TABLE content_comparisons DROP CONSTRAINT content_comparisons_we_do_better_length_check"
      end

      statement :stay_with_them_length_check do
        up "ALTER TABLE content_comparisons ADD CONSTRAINT content_comparisons_stay_with_them_length_check CHECK (octet_length(stay_with_them::text) <= 20000)"

        down "ALTER TABLE content_comparisons DROP CONSTRAINT content_comparisons_stay_with_them_length_check"
      end

      statement :switch_to_us_length_check do
        up "ALTER TABLE content_comparisons ADD CONSTRAINT content_comparisons_switch_to_us_length_check CHECK (octet_length(switch_to_us::text) <= 20000)"

        down "ALTER TABLE content_comparisons DROP CONSTRAINT content_comparisons_switch_to_us_length_check"
      end

      statement :migration_length_check do
        up "ALTER TABLE content_comparisons ADD CONSTRAINT content_comparisons_migration_length_check CHECK (octet_length(migration::text) <= 30000)"

        down "ALTER TABLE content_comparisons DROP CONSTRAINT content_comparisons_migration_length_check"
      end

      statement :unverified_length_check do
        up "ALTER TABLE content_comparisons ADD CONSTRAINT content_comparisons_unverified_length_check CHECK (octet_length(unverified::text) <= 20000)"

        down "ALTER TABLE content_comparisons DROP CONSTRAINT content_comparisons_unverified_length_check"
      end

      statement :faqs_length_check do
        up "ALTER TABLE content_comparisons ADD CONSTRAINT content_comparisons_faqs_length_check CHECK (octet_length(faqs::text) <= 30000)"

        down "ALTER TABLE content_comparisons DROP CONSTRAINT content_comparisons_faqs_length_check"
      end

      statement :sources_length_check do
        up "ALTER TABLE content_comparisons ADD CONSTRAINT content_comparisons_sources_length_check CHECK (octet_length(sources::text) <= 20000)"

        down "ALTER TABLE content_comparisons DROP CONSTRAINT content_comparisons_sources_length_check"
      end

      # ARCHITECTURE.md §5 rule 5: text + CHECK for enums.
      statement :status_enum_check do
        up "ALTER TABLE content_comparisons ADD CONSTRAINT content_comparisons_status_enum_check CHECK (status IN ('draft', 'published'))"

        down "ALTER TABLE content_comparisons DROP CONSTRAINT content_comparisons_status_enum_check"
      end

      # Alplus.Seo.Inventory (PRD §39, §40), moved onto the content row so
      # the inventory is read at runtime instead of duplicated as a literal.
      statement :intent_enum_check do
        up "ALTER TABLE content_comparisons ADD CONSTRAINT content_comparisons_intent_enum_check CHECK (intent IN ('informational', 'commercial_investigation', 'transactional', 'navigational'))"

        down "ALTER TABLE content_comparisons DROP CONSTRAINT content_comparisons_intent_enum_check"
      end

      statement :cluster_length_check do
        up "ALTER TABLE content_comparisons ADD CONSTRAINT content_comparisons_cluster_length_check CHECK (octet_length(cluster) <= 100)"

        down "ALTER TABLE content_comparisons DROP CONSTRAINT content_comparisons_cluster_length_check"
      end

      statement :primary_query_length_check do
        up "ALTER TABLE content_comparisons ADD CONSTRAINT content_comparisons_primary_query_length_check CHECK (octet_length(primary_query) <= 200)"

        down "ALTER TABLE content_comparisons DROP CONSTRAINT content_comparisons_primary_query_length_check"
      end
    end
  end

  actions do
    defaults [:read, :destroy]

    read :get_by_path do
      argument :path, :string, allow_nil?: false
      get? true
      filter expr(path == ^arg(:path))
    end

    read :get_by_slug do
      argument :slug, :string, allow_nil?: false
      get? true
      filter expr(slug == ^arg(:slug))
    end

    create :create do
      accept [
        :slug,
        :path,
        :title,
        :meta_description,
        :nav_label,
        :summary,
        :lastmod,
        :competitor_name,
        :competitor_homepage,
        :positioning,
        :tldr,
        :body_sections,
        :why_looking,
        :free_tier_rows,
        :they_do_better,
        :we_do_better,
        :stay_with_them,
        :switch_to_us,
        :migration,
        :unverified,
        :faqs,
        :sources,
        :status,
        :cluster,
        :intent,
        :primary_query
      ]
    end

    update :update do
      accept [
        :title,
        :meta_description,
        :nav_label,
        :summary,
        :lastmod,
        :competitor_name,
        :competitor_homepage,
        :positioning,
        :tldr,
        :body_sections,
        :why_looking,
        :free_tier_rows,
        :they_do_better,
        :we_do_better,
        :stay_with_them,
        :switch_to_us,
        :migration,
        :unverified,
        :faqs,
        :sources,
        :status,
        :cluster,
        :intent,
        :primary_query
      ]
    end
  end

  # Public read of published comparisons only; writes require
  # `authorize?: false` (see Alplus.Content.Page moduledoc — same rule).
  policies do
    policy action_type(:read) do
      authorize_if expr(status == "published")
    end
  end

  attributes do
    attribute :id, Alplus.Id do
      constraints prefix: "comparison"
      public? true
      writable? false
      primary_key? true
      allow_nil? false
      default fn -> Alplus.Id.generate("comparison") end
    end

    attribute :slug, :string do
      allow_nil? false
      public? true
      constraints max_length: 100, match: ~r/\A[a-z0-9]([a-z0-9-]*[a-z0-9])?\z/
    end

    attribute :path, :string do
      allow_nil? false
      public? true
      constraints max_length: 200
    end

    attribute :title, :string do
      allow_nil? false
      public? true
      constraints max_length: 300
    end

    attribute :meta_description, :string do
      allow_nil? false
      public? true
      constraints max_length: 500
    end

    attribute :nav_label, :string do
      public? true
      constraints max_length: 100
    end

    attribute :summary, :string do
      allow_nil? false
      public? true
      constraints max_length: 500
    end

    attribute :lastmod, :date do
      allow_nil? false
      public? true
    end

    attribute :competitor_name, :string do
      allow_nil? false
      public? true
      constraints max_length: 200
    end

    attribute :competitor_homepage, :string do
      allow_nil? false
      public? true
      constraints max_length: 500
    end

    attribute :positioning, :string do
      allow_nil? false
      public? true
      constraints max_length: 1000
    end

    attribute :tldr, :string do
      allow_nil? false
      public? true
      constraints max_length: 2000
    end

    # Prose comparisons that a feature table cannot carry: the tier-by-tier
    # pricing walk and the one dimension that decides the page. Same
    # `%{"heading" => , "body" => [..]}` shape as `Alplus.Content.Page`, so
    # `AlplusWeb.MarketingComponents.body_sections/1` renders both.
    attribute :body_sections, {:array, :map} do
      public? true
      default []
    end

    # Each list attribute below is an ordered array — string bullets, or
    # `%{"label"=>, "them"=>, "us"=>, "edge"=>}` maps for `free_tier_rows`
    # and `%{"q"=>, "a"=>}` for `faqs`, `%{"label"=>, "url"=>,
    # "retrieved"=>}` for `sources` — mirroring `Competitor` in
    # `competitors.ts` field for field.
    attribute :why_looking, {:array, :string} do
      public? true
      default []
    end

    attribute :free_tier_rows, {:array, :map} do
      public? true
      default []
    end

    attribute :they_do_better, {:array, :string} do
      public? true
      default []
    end

    attribute :we_do_better, {:array, :string} do
      public? true
      default []
    end

    attribute :stay_with_them, {:array, :string} do
      public? true
      default []
    end

    attribute :switch_to_us, {:array, :string} do
      public? true
      default []
    end

    attribute :migration, {:array, :string} do
      public? true
      default []
    end

    attribute :unverified, {:array, :string} do
      public? true
      default []
    end

    attribute :faqs, {:array, :map} do
      public? true
      default []
    end

    attribute :sources, {:array, :map} do
      public? true
      default []
    end

    attribute :status, :string do
      allow_nil? false
      public? true
      default "published"
      constraints match: ~r/\A(draft|published)\z/
    end

    # Alplus.Seo.Inventory (PRD §39, §40): what cluster this page reports
    # into, what search intent it serves, and the one query it targets.
    attribute :cluster, :string do
      allow_nil? false
      public? true
      constraints max_length: 100
    end

    attribute :intent, :string do
      allow_nil? false
      public? true

      constraints match:
                    ~r/\A(informational|commercial_investigation|transactional|navigational)\z/
    end

    attribute :primary_query, :string do
      allow_nil? false
      public? true
      constraints max_length: 200
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_slug, [:slug]
    identity :unique_path, [:path]
  end
end
