defmodule Alplus.PublicPages do
  @moduledoc """
  Domain interface for the one public-page identity owned by each project.

  Status pages and changelogs keep their legacy records during the expand
  phase. This domain owns the shared public slug, branding, and publication
  state that the public surfaces render.
  """

  use Ash.Domain, otp_app: :alplus

  alias Alplus.PublicPages.{API, PublicPage, Public}

  resources do
    resource PublicPage do
      define :create_public_page, action: :create
      define :get_public_page, action: :read, get_by: [:id]
      define :get_public_page_for_project, action: :for_project, args: [:org_id, :project_id]
      define :update_public_page, action: :update
      define :publish_public_page, action: :publish
      define :unpublish_public_page, action: :unpublish
    end

    resource Alplus.PublicPages.PublicPageAlias
  end

  defdelegate create_identity(scope, attrs), to: API, as: :create
  defdelegate ensure_identity(scope, attrs), to: API
  defdelegate update(scope, identity, attrs), to: API
  defdelegate update(scope, identity, attrs, opts), to: API
  defdelegate publish(scope, identity), to: API
  defdelegate unpublish(scope, identity), to: API
  defdelegate get_for_project(scope, project_id), to: API
  defdelegate get_for_scope(scope), to: API
  defdelegate aliases_for_project(scope, project_id), to: API
  defdelegate public_identity_for_project(project_id), to: Public
  defdelegate public_alias_for_slug(slug), to: Public
  defdelegate public_alias_for_slug(slug, opts), to: Public
  defdelegate resolve(slug), to: Public
  defdelegate resolve(slug, opts), to: Public
  defdelegate resolve_changelog(slug), to: Public
  defdelegate reserve_alias(scope, identity, slug, kind, source_id), to: API
  defdelegate reserve_alias_system(identity, slug, kind, source_id), to: API
  defdelegate slug_with_project_token(slug, public_token), to: Public
end
