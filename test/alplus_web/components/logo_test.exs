defmodule AlplusWeb.CoreComponents.LogoTest do
  @moduledoc """
  The canonical logo lockup (`CoreComponents.logo/1`). Asserts the
  accessibility contract, not the markup: one accessible name per lockup, a
  decorative mark when text already names PostDeploy, and the inline mark SVG.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  import AlplusWeb.CoreComponents, only: [logo: 1]

  defp markup(assigns), do: rendered_to_string(logo(Map.put(assigns, :__changed__, nil)))

  test "linked lockup names itself once and keeps the mark decorative" do
    html = markup(%{href: "/"})

    assert html =~ ~s(href="/")
    assert html =~ ~s(aria-label="PostDeploy home")
    # The wordmark text is present but the mark is decorative, so a screen
    # reader announces the anchor's label once, not "PostDeploy home PostDeploy".
    assert html =~ ~s(viewBox="0 0 512 512")
    assert html =~ ~s(aria-hidden="true")
    assert length(Regex.scan(~r/<path\b/, html)) == 2
    assert html =~ "postdeploy"
    assert html =~ "text-text-primary"
  end

  test "standalone mark carries the name itself (no adjacent text)" do
    html = markup(%{variant: :mark, size: :lg, label: "PostDeploy"})

    refute html =~ "<a"
    assert html =~ ~s(role="img")
    assert html =~ ~s(aria-label="PostDeploy")
    refute html =~ "postdeploy<span"
    assert html =~ "size-11"
  end

  test "wordmark variant draws text only, no mark" do
    html = markup(%{variant: :wordmark})

    refute html =~ "<svg"
    assert html =~ "text-text-primary"
    assert html =~ "postdeploy"
  end
end
