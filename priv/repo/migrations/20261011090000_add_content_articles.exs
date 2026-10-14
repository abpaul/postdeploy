defmodule Alplus.Repo.Migrations.AddContentArticles do
  use Ecto.Migration

  def change do
    create table(:content_articles, primary_key: false) do
      add :id, :text, null: false, primary_key: true
      add :slug, :text, null: false
      add :title, :text, null: false
      add :description, :text, null: false
      add :published_at, :utc_datetime_usec, null: false
      add :keywords, {:array, :text}, null: false
      add :cluster, :text, null: false
      add :intent, :text, null: false
      add :internal_links, {:array, :text}, null: false, default: []
      add :sources, {:array, :text}, null: false, default: []
      add :body_html, :text, null: false

      timestamps(type: :utc_datetime_usec, default: fragment("(now() AT TIME ZONE 'utc')"))
    end

    create unique_index(:content_articles, [:slug], name: :content_articles_unique_slug_index)

    create constraint(:content_articles, :content_articles_cluster_check,
             check: "cluster IN ('uptime', 'cron', 'errors', 'analytics', 'observability')"
           )

    create constraint(:content_articles, :content_articles_intent_check,
             check: "intent IN ('informational', 'commercial_investigation')"
           )
  end
end
