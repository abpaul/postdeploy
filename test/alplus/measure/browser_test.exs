defmodule Alplus.Measure.BrowserTest do
  use ExUnit.Case, async: true

  alias Alplus.Measure.Browser

  @chrome "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
  @safari "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"
  @firefox "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:127.0) Gecko/20100101 Firefox/127.0"
  @edge "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36 Edg/126.0.0.0"
  @samsung "Mozilla/5.0 (Linux; Android 14; SM-S918B) AppleWebKit/537.36 (KHTML, like Gecko) SamsungBrowser/25.0 Chrome/122.0.0.0 Mobile Safari/537.36"
  @opera "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36 OPR/112.0.0.0"

  test "classifies each closed-set browser correctly, engine markers checked before Chrome/Safari" do
    assert Browser.label(@chrome) == "Chrome"
    assert Browser.label(@safari) == "Safari"
    assert Browser.label(@firefox) == "Firefox"
    assert Browser.label(@edge) == "Edge"
    assert Browser.label(@samsung) == "Samsung"
    assert Browser.label(@opera) == "Opera"
  end

  test "an unrecognized or absent user agent falls into Other, never the raw string" do
    assert Browser.label("SomeUnknownBot/1.0") == "Other"
    assert Browser.label(nil) == "Other"
    assert Browser.label("") == "Other"
  end

  test "labels/0 is the closed set" do
    assert Browser.labels() == ~w(Edge Opera Samsung Firefox Chrome Safari Other)
  end
end
