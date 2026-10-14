defmodule Alplus.Content.Guide do
  @moduledoc """
  A cornerstone/pillar content page (ARCHITECTURE.md §3, §9), e.g.
  `/free-uptime-monitoring` and `/free-cron-job-monitoring`. Public, not
  tenant-owned — no `org_id`.

  Ported from `workers/www/site/lib/pages.ts` (`SitePage`) plus the per-page
  hero/body/FAQ copy in `workers/www/site/pages/free-*.astro`.
  """

  use Ash.Resource,
    otp_app: :alplus,
    domain: Alplus.Content,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "content_guides"
    repo Alplus.Repo

    custom_statements do
      statement :title_length_check do
        up "ALTER TABLE content_guides ADD CONSTRAINT content_guides_title_length_check CHECK (octet_length(title) <= 300)"
        down "ALTER TABLE content_guides DROP CONSTRAINT content_guides_title_length_check"
      end

      statement :meta_description_length_check do
        up "ALTER TABLE content_guides ADD CONSTRAINT content_guides_meta_description_length_check CHECK (octet_length(meta_description) <= 500)"

        down "ALTER TABLE content_guides DROP CONSTRAINT content_guides_meta_description_length_check"
      end

      statement :summary_length_check do
        up "ALTER TABLE content_guides ADD CONSTRAINT content_guides_summary_length_check CHECK (octet_length(summary) <= 500)"
        down "ALTER TABLE content_guides DROP CONSTRAINT content_guides_summary_length_check"
      end

      statement :hero_description_length_check do
        up "ALTER TABLE content_guides ADD CONSTRAINT content_guides_hero_description_length_check CHECK (octet_length(hero_description) <= 2000)"

        down "ALTER TABLE content_guides DROP CONSTRAINT content_guides_hero_description_length_check"
      end

      statement :body_sections_length_check do
        up "ALTER TABLE content_guides ADD CONSTRAINT content_guides_body_sections_length_check CHECK (octet_length(body_sections::text) <= 200000)"

        down "ALTER TABLE content_guides DROP CONSTRAINT content_guides_body_sections_length_check"
      end

      statement :faqs_length_check do
        up "ALTER TABLE content_guides ADD CONSTRAINT content_guides_faqs_length_check CHECK (octet_length(faqs::text) <= 50000)"
        down "ALTER TABLE content_guides DROP CONSTRAINT content_guides_faqs_length_check"
      end

      # ARCHITECTURE.md §5 rule 5: text + CHECK for enums.
      statement :status_enum_check do
        up "ALTER TABLE content_guides ADD CONSTRAINT content_guides_status_enum_check CHECK (status IN ('draft', 'published'))"
        down "ALTER TABLE content_guides DROP CONSTRAINT content_guides_status_enum_check"
      end

      # SITE-ARCHITECTURE.md §8 publish gate fields, only populated on
      # platform-heartbeat guides (see the `Content.PublishGate` moduledoc).
      statement :platform_length_check do
        up "ALTER TABLE content_guides ADD CONSTRAINT content_guides_platform_length_check CHECK (octet_length(platform) <= 100)"
        down "ALTER TABLE content_guides DROP CONSTRAINT content_guides_platform_length_check"
      end

      statement :docs_host_length_check do
        up "ALTER TABLE content_guides ADD CONSTRAINT content_guides_docs_host_length_check CHECK (octet_length(docs_host) <= 255)"
        down "ALTER TABLE content_guides DROP CONSTRAINT content_guides_docs_host_length_check"
      end

      statement :platform_failure_mode_length_check do
        up "ALTER TABLE content_guides ADD CONSTRAINT content_guides_platform_failure_mode_length_check CHECK (octet_length(platform_failure_mode) <= 2000)"

        down "ALTER TABLE content_guides DROP CONSTRAINT content_guides_platform_failure_mode_length_check"
      end

      statement :sources_length_check do
        up "ALTER TABLE content_guides ADD CONSTRAINT content_guides_sources_length_check CHECK (octet_length(sources::text) <= 20000)"
        down "ALTER TABLE content_guides DROP CONSTRAINT content_guides_sources_length_check"
      end

      statement :not_offered_length_check do
        up "ALTER TABLE content_guides ADD CONSTRAINT content_guides_not_offered_length_check CHECK (octet_length(not_offered::text) <= 10000)"
        down "ALTER TABLE content_guides DROP CONSTRAINT content_guides_not_offered_length_check"
      end

      # Alplus.Seo.Inventory (PRD §39, §40), moved onto the content row so
      # the inventory is read at runtime instead of duplicated as a literal.
      statement :intent_enum_check do
        up "ALTER TABLE content_guides ADD CONSTRAINT content_guides_intent_enum_check CHECK (intent IN ('informational', 'commercial_investigation', 'transactional', 'navigational'))"
        down "ALTER TABLE content_guides DROP CONSTRAINT content_guides_intent_enum_check"
      end

      statement :cluster_length_check do
        up "ALTER TABLE content_guides ADD CONSTRAINT content_guides_cluster_length_check CHECK (octet_length(cluster) <= 100)"
        down "ALTER TABLE content_guides DROP CONSTRAINT content_guides_cluster_length_check"
      end

      statement :primary_query_length_check do
        up "ALTER TABLE content_guides ADD CONSTRAINT content_guides_primary_query_length_check CHECK (octet_length(primary_query) <= 200)"

        down "ALTER TABLE content_guides DROP CONSTRAINT content_guides_primary_query_length_check"
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
        :hero_badge,
        :hero_heading,
        :hero_description,
        :body_sections,
        :faqs,
        :related_guide_path,
        :cta_heading,
        :cta_label,
        :related_paths,
        :author_name,
        :published_on,
        :last_verified_on,
        :lastmod,
        :status,
        :platform,
        :docs_host,
        :platform_failure_mode,
        :sources,
        :not_offered,
        :code_verified_on,
        :cluster,
        :intent,
        :primary_query
      ]

      validate Alplus.Content.Validations.SourcesMatchDocsHost
      validate Alplus.Content.Validations.SourcesRetrievedRecently
      validate Alplus.Content.Validations.NotOfferedPresent
    end

    update :update do
      accept [
        :title,
        :meta_description,
        :nav_label,
        :summary,
        :hero_badge,
        :hero_heading,
        :hero_description,
        :body_sections,
        :faqs,
        :related_guide_path,
        :cta_heading,
        :cta_label,
        :related_paths,
        :author_name,
        :published_on,
        :last_verified_on,
        :lastmod,
        :status,
        :platform,
        :docs_host,
        :platform_failure_mode,
        :sources,
        :not_offered,
        :code_verified_on,
        :cluster,
        :intent,
        :primary_query
      ]

      require_atomic? false
      validate Alplus.Content.Validations.SourcesMatchDocsHost
      validate Alplus.Content.Validations.SourcesRetrievedRecently
      validate Alplus.Content.Validations.NotOfferedPresent
    end
  end

  # Public read of published guides only; writes require `authorize?: false`
  # (see Alplus.Content.Page moduledoc — same rule, no write policy here).
  policies do
    policy action_type(:read) do
      authorize_if expr(status == "published")
    end
  end

  attributes do
    attribute :id, Alplus.Id do
      constraints prefix: "guide"
      public? true
      writable? false
      primary_key? true
      allow_nil? false
      default fn -> Alplus.Id.generate("guide") end
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

    # Ordered list of `%{"heading" => ..., "body" => [...], "code" => nil |
    # "...", "list" => [...]}` maps — one per <section> in the old .astro
    # page, kept structured so a generator can consume it later.
    attribute :body_sections, {:array, :map} do
      public? true
      default []
    end

    attribute :faqs, {:array, :map} do
      public? true
      default []
    end

    attribute :related_guide_path, :string do
      public? true
      constraints max_length: 200
    end

    # Contextual conversion and linking, per ARCHITECTURE.md §9's rule that
    # marketing copy is data, not template literals.
    #
    # `cta_heading`/`cta_label` let each page ask for the action that fits its
    # intent ("Monitor this job with PostDeploy" on a guide, "See how PostDeploy fits your
    # stack" on a comparison) instead of one site-wide CTA. Both are optional;
    # the template falls back to the shared default.
    attribute :cta_heading, :string do
      public? true
      constraints max_length: 200
    end

    attribute :cta_label, :string do
      public? true
      constraints max_length: 100
    end

    # Ordered `%{"path" => ..., "label" => ...}` maps naming the pages this
    # one should link to. An explicit editorial relationship, never a
    # keyword match, and `Alplus.Seo.Audit` fails the build when a path here
    # does not resolve.
    attribute :related_paths, {:array, :map} do
      public? true
      default []
    end

    attribute :lastmod, :date do
      allow_nil? false
      public? true
    end

    # Authorship and dating for editorial content (PRD §16, §34). Optional,
    # because a commercial product page is not an article and inventing a
    # byline for one would be fabricated authorship.
    #
    # `last_verified_on` is the claim that matters for a guide about someone
    # else's software: it says when a human last checked the external facts,
    # which `lastmod` (a sitemap signal) does not.
    attribute :author_name, :string do
      public? true
      constraints max_length: 100
    end

    attribute :published_on, :date do
      public? true
    end

    attribute :last_verified_on, :date do
      public? true
    end

    # SITE-ARCHITECTURE.md §8 publish gate fields. Only the platform-heartbeat
    # guides (`/guides/{platform}-heartbeat`) populate these; every other
    # Guide row (`/privacy`, `/monitoring`, ...) leaves them nil, and the
    # per-row validations below only fire when `docs_host` is present.
    attribute :platform, :string do
      public? true
      constraints max_length: 100
    end

    # The hostname the platform's own documentation is served from, e.g.
    # "docs.github.com". Every `sources` entry that backs the failure-mode
    # claim must resolve to this host (enforced below), so a citation cannot
    # silently point somewhere other than the platform it claims to describe.
    attribute :docs_host, :string do
      public? true
      constraints max_length: 255
    end

    # The specific, citable way this platform's scheduler fails silently
    # (SITE-ARCHITECTURE.md §8 condition 3), e.g. "GitHub disables a
    # scheduled workflow after 60 days of repository inactivity."
    attribute :platform_failure_mode, :string do
      public? true
      constraints max_length: 2000
    end

    # Ordered `%{"label" => ..., "url" => ..., "retrieved" => "YYYY-MM-DD"}`
    # maps, same shape as `Alplus.Content.Comparison.sources`. Backs the
    # failure-mode citation with the platform's own documentation and a
    # retrieval date.
    attribute :sources, {:array, :map} do
      public? true
      default []
    end

    # What PostDeploy does not do for this platform (SITE-ARCHITECTURE.md §8
    # condition 4), rendered on the page so the citation is not just data at
    # rest.
    attribute :not_offered, {:array, :string} do
      public? true
      default []
    end

    # The date a human last ran the page's code sample end to end
    # (SITE-ARCHITECTURE.md §8 condition 2). `Content.PublishGate` requires
    # an attestation but does not expire it after an unrelated copy edit.
    # Update this date when a changed sample is run again.
    attribute :code_verified_on, :date do
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
