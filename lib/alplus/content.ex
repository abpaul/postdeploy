defmodule Alplus.Content do
  @moduledoc """
  Marketing content: `Page`, `Guide`, and `Comparison` (ARCHITECTURE.md §3, §9).

  Content is public and not tenant-owned — no `org_id` anywhere in this
  domain. Every resource's read policy allows anyone to read published rows;
  every write (here, in seeds, and in any future admin tooling) must pass
  `authorize?: false` explicitly, since no resource defines a write policy
  that would authorize it otherwise. Load through these code-interface
  functions or `Ash.*`, never `Alplus.Repo` directly (BUILD.md §2 rule 3).
  """

  use Ash.Domain,
    otp_app: :alplus

  resources do
    resource Alplus.Content.Article do
      define :create_article, action: :create
      define :get_article_by_id, action: :get_by_id, args: [:id]
      define :get_article_by_slug, action: :get_by_slug, args: [:slug]
      define :list_articles, action: :read
      define :update_article, action: :update
    end

    resource Alplus.Content.Page do
      define :create_page, action: :create
      define :get_page_by_path, action: :get_by_path, args: [:path]
      define :get_page_by_slug, action: :get_by_slug, args: [:slug]
      define :list_pages, action: :read
      define :update_page, action: :update
      define :destroy_page, action: :destroy
    end

    resource Alplus.Content.Guide do
      define :create_guide, action: :create
      define :get_guide_by_path, action: :get_by_path, args: [:path]
      define :get_guide_by_slug, action: :get_by_slug, args: [:slug]
      define :list_guides, action: :read
      define :update_guide, action: :update
      define :destroy_guide, action: :destroy
    end

    resource Alplus.Content.Comparison do
      define :create_comparison, action: :create
      define :get_comparison_by_path, action: :get_by_path, args: [:path]
      define :get_comparison_by_slug, action: :get_by_slug, args: [:slug]
      define :list_comparisons, action: :read
      define :update_comparison, action: :update
      define :destroy_comparison, action: :destroy
    end
  end
end
