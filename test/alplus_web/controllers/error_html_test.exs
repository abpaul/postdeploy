defmodule AlplusWeb.ErrorHTMLTest do
  use AlplusWeb.ConnCase, async: true

  # Bring render_to_string/4 for testing custom views
  import Phoenix.Template, only: [render_to_string: 4]

  test "renders 404.html" do
    html = render_to_string(AlplusWeb.ErrorHTML, "404", "html", [])
    assert html =~ "Page not found"
    assert html =~ ~s(content="noindex")
  end

  test "renders 500.html" do
    assert render_to_string(AlplusWeb.ErrorHTML, "500", "html", []) == "Internal Server Error"
  end
end
