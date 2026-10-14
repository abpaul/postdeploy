defmodule Alplus.Content.Page do
  @moduledoc """
  A general marketing page (home, pricing, alternatives index, legal —
  ARCHITECTURE.md §3, §9). Content is public and not tenant-owned: there is
  no `org_id` here, unlike every resource in `Alplus.Orgs`/`Alplus.Projects`.

  Ported from `workers/www/site/lib/pages.ts` (`SitePage`) plus the per-page
  hero/body copy in `workers/www/site/pages/*.astro`.
  """

  use Ash.Resource,
    otp_app: :alplus,
    domain: Alplus.Content,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "content_pages"
    repo Alplus.Repo

    custom_statements do
      statement :title_length_check do
        up "ALTER TABLE content_pages ADD CONSTRAINT content_pages_title_length_check CHECK (octet_length(title) <= 300)"
        down "ALTER TABLE content_pages DROP CONSTRAINT content_pages_title_length_check"
      end

      statement :meta_description_length_check do
        up "ALTER TABLE content_pages ADD CONSTRAINT content_pages_meta_description_length_check CHECK (octet_length(meta_description) <= 500)"

        down "ALTER TABLE content_pages DROP CONSTRAINT content_pages_meta_description_length_check"
      end

      statement :og_title_length_check do
        up "ALTER TABLE content_pages ADD CONSTRAINT content_pages_og_title_length_check CHECK (octet_length(og_title) <= 300)"
        down "ALTER TABLE content_pages DROP CONSTRAINT content_pages_og_title_length_check"
      end

      statement :og_description_length_check do
        up "ALTER TABLE content_pages ADD CONSTRAINT content_pages_og_description_length_check CHECK (octet_length(og_description) <= 500)"
        down "ALTER TABLE content_pages DROP CONSTRAINT content_pages_og_description_length_check"
      end

      statement :summary_length_check do
        up "ALTER TABLE content_pages ADD CONSTRAINT content_pages_summary_length_check CHECK (octet_length(summary) <= 500)"
        down "ALTER TABLE content_pages DROP CONSTRAINT content_pages_summary_length_check"
      end

      statement :hero_description_length_check do
        up "ALTER TABLE content_pages ADD CONSTRAINT content_pages_hero_description_length_check CHECK (octet_length(hero_description) <= 2000)"

        down "ALTER TABLE content_pages DROP CONSTRAINT content_pages_hero_description_length_check"
      end

      statement :body_sections_length_check do
        up "ALTER TABLE content_pages ADD CONSTRAINT content_pages_body_sections_length_check CHECK (octet_length(body_sections::text) <= 100000)"
        down "ALTER TABLE content_pages DROP CONSTRAINT content_pages_body_sections_length_check"
      end

      statement :faqs_length_check do
        up "ALTER TABLE content_pages ADD CONSTRAINT content_pages_faqs_length_check CHECK (octet_length(faqs::text) <= 50000)"
        down "ALTER TABLE content_pages DROP CONSTRAINT content_pages_faqs_length_check"
      end

      # ARCHITECTURE.md §5 rule 5: text + CHECK for enums.
      statement :group_enum_check do
        up "ALTER TABLE content_pages ADD CONSTRAINT content_pages_group_enum_check CHECK (\"group\" IN ('core', 'alternatives'))"
        down "ALTER TABLE content_pages DROP CONSTRAINT content_pages_group_enum_check"
      end

      statement :priority_enum_check do
        up "ALTER TABLE content_pages ADD CONSTRAINT content_pages_priority_enum_check CHECK (priority IN ('1.0', '0.8'))"
        down "ALTER TABLE content_pages DROP CONSTRAINT content_pages_priority_enum_check"
      end

      statement :status_enum_check do
        up "ALTER TABLE content_pages ADD CONSTRAINT content_pages_status_enum_check CHECK (status IN ('draft', 'published'))"
        down "ALTER TABLE content_pages DROP CONSTRAINT content_pages_status_enum_check"
      end

      # Alplus.Seo.Inventory (PRD §39, §40), moved onto the content row so
      # the inventory is read at runtime instead of duplicated as a literal.
      statement :intent_enum_check do
        up "ALTER TABLE content_pages ADD CONSTRAINT content_pages_intent_enum_check CHECK (intent IN ('informational', 'commercial_investigation', 'transactional', 'navigational'))"
        down "ALTER TABLE content_pages DROP CONSTRAINT content_pages_intent_enum_check"
      end

      statement :cluster_length_check do
        up "ALTER TABLE content_pages ADD CONSTRAINT content_pages_cluster_length_check CHECK (octet_length(cluster) <= 100)"
        down "ALTER TABLE content_pages DROP CONSTRAINT content_pages_cluster_length_check"
      end

      statement :primary_query_length_check do
        up "ALTER TABLE content_pages ADD CONSTRAINT content_pages_primary_query_length_check CHECK (octet_length(primary_query) <= 200)"
        down "ALTER TABLE content_pages DROP CONSTRAINT content_pages_primary_query_length_check"
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
        :og_title,
        :og_description,
        :nav_label,
        :summary,
        :hero_badge,
        :hero_heading,
        :hero_description,
        :body_sections,
        :faqs,
        :group,
        :priority,
        :lastmod,
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
        :og_title,
        :og_description,
        :nav_label,
        :summary,
        :hero_badge,
        :hero_heading,
        :hero_description,
        :body_sections,
        :faqs,
        :group,
        :priority,
        :lastmod,
        :status,
        :cluster,
        :intent,
        :primary_query
      ]
    end
  end

  # Read policy: anyone (no actor required) may read a published page — the
  # marketing site is public and unauthenticated. Writes have no authorize_if
  # clause below, so they are denied for any policy-checked call; every
  # write in this codebase (seed, future admin tooling) must pass
  # `authorize?: false` explicitly to bypass Ash.Policy.Authorizer.
  policies do
    policy action_type(:read) do
      authorize_if expr(status == "published")
    end
  end

  attributes do
    attribute :id, Alplus.Id do
      constraints prefix: "page"
      public? true
      writable? false
      primary_key? true
      allow_nil? false
      default fn -> Alplus.Id.generate("page") end
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

    attribute :og_title, :string do
      public? true
      constraints max_length: 300
    end

    attribute :og_description, :string do
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

    attribute :hero_badge, :string do
      public? true
      constraints max_length: 100
    end

    attribute :hero_heading, :string do
      public? true
      constraints max_length: 300
    end

    attribute :hero_description, :string do
      public? true
      constraints max_length: 2000
    end

    # Ordered list of `%{"heading" => ..., "body" => ..., "list" => [...]}`
    # maps — one per <section>/<h2> in the old .astro page. Kept structured
    # (not raw HTML) so a programmatic SEO generator can consume it later.
    attribute :body_sections, {:array, :map} do
      public? true
      default []
    end

    attribute :faqs, {:array, :map} do
      public? true
      default []
    end

    attribute :group, :string do
      allow_nil? false
      public? true
      default "core"
      constraints match: ~r/\A(core|alternatives)\z/
    end

    attribute :priority, :string do
      allow_nil? false
      public? true
      default "0.8"
      constraints match: ~r/\A(1\.0|0\.8)\z/
    end

    attribute :lastmod, :date do
      allow_nil? false
      public? true
    end

    attribute :status, :string do
      allow_nil? false
      public? true
      default "published"
      constraints match: ~r/\A(draft|published)\z/
    end

    # Alplus.Seo.Inventory (PRD §39, §40): what cluster this page reports
    # into, what search intent it serves, and the one query it targets.
    # `allow_nil? false` is the enforcement that a compile-time inventory
    # literal used to provide by hand: a page cannot be created without
    # declaring these, so it cannot silently go undeclared.
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
