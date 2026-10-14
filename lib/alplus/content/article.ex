defmodule Alplus.Content.Article do
  @moduledoc "A scheduled, public Markdown article in the SEO blog."

  use Ash.Resource,
    otp_app: :alplus,
    domain: Alplus.Content,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "content_articles"
    repo Alplus.Repo

    custom_statements do
      statement :cluster_check do
        up "ALTER TABLE content_articles ADD CONSTRAINT content_articles_cluster_check CHECK (cluster IN ('uptime', 'cron', 'errors', 'analytics', 'observability'))"
        down "ALTER TABLE content_articles DROP CONSTRAINT content_articles_cluster_check"
      end

      statement :intent_check do
        up "ALTER TABLE content_articles ADD CONSTRAINT content_articles_intent_check CHECK (intent IN ('informational', 'commercial_investigation'))"
        down "ALTER TABLE content_articles DROP CONSTRAINT content_articles_intent_check"
      end
    end
  end

  actions do
    defaults [:read]

    read :get_by_id do
      argument :id, :string, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :get_by_slug do
      argument :slug, :string, allow_nil?: false
      get? true
      filter expr(slug == ^arg(:slug))
    end

    create :create do
      accept [
        :slug,
        :title,
        :description,
        :published_at,
        :keywords,
        :cluster,
        :intent,
        :internal_links,
        :sources,
        :body_html
      ]
    end

    update :update do
      accept [
        :title,
        :description,
        :published_at,
        :keywords,
        :cluster,
        :intent,
        :internal_links,
        :sources,
        :body_html
      ]

      require_atomic? false
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if expr(published_at <= now())
    end
  end

  attributes do
    attribute :id, Alplus.Id do
      constraints prefix: "article"
      public? true
      writable? false
      primary_key? true
      allow_nil? false
      default fn -> Alplus.Id.generate("article") end
    end

    attribute :slug, :string do
      allow_nil? false
      public? true
      constraints max_length: 120, match: ~r/\A[a-z0-9]([a-z0-9-]*[a-z0-9])?\z/
    end

    attribute :title, :string do
      allow_nil? false
      public? true
      constraints max_length: 300
    end

    attribute :description, :string do
      allow_nil? false
      public? true
      constraints max_length: 500
    end

    attribute :published_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :keywords, {:array, :string} do
      allow_nil? false
      public? true
      constraints min_length: 1, items: [min_length: 1]
    end

    attribute :cluster, :string do
      allow_nil? false
      public? true
      constraints match: ~r/\A(uptime|cron|errors|analytics|observability)\z/
    end

    attribute :intent, :string do
      allow_nil? false
      public? true
      constraints match: ~r/\A(informational|commercial_investigation)\z/
    end

    attribute :internal_links, {:array, :string} do
      allow_nil? false
      public? true
      default []
    end

    attribute :sources, {:array, :string} do
      allow_nil? false
      public? true
      default []
    end

    attribute :body_html, :string do
      allow_nil? false
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_slug, [:slug]
  end
end
