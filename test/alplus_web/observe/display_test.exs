defmodule AlplusWeb.Observe.DisplayTest do
  use ExUnit.Case, async: true

  alias AlplusWeb.Observe.Display

  test "level_tone/1 maps every level" do
    assert Display.level_tone("fatal") == "error"
    assert Display.level_tone("error") == "error"
    assert Display.level_tone("warning") == "warning"
    assert Display.level_tone("info") == "info"
    assert Display.level_tone("debug") == "neutral"
  end

  test "status_label/1 maps every issue status" do
    assert Display.status_label(:open) == "Open"
    assert Display.status_label(:resolved) == "Resolved"
    assert Display.status_label(:ignored) == "Ignored"
    assert Display.status_label(:merged) == "Merged"
  end

  test "option labels name the unfiltered choice" do
    assert Display.level_option_label("all") == "All levels"
    assert Display.level_option_label("error") == "Error"
    assert Display.status_option_label("all") == "All statuses"
    assert Display.status_option_label("open") == "Open"
  end
end
