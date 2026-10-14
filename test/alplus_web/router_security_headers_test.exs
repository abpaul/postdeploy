defmodule AlplusWeb.RouterSecurityHeadersTest do
  use AlplusWeb.ConnCase, async: true

  test "browser-pipeline routes get a per-request CSP with a script-src nonce", %{conn: conn} do
    conn = get(conn, "/")

    [csp] = get_resp_header(conn, "content-security-policy")
    assert csp =~ "default-src 'self'"
    assert csp =~ "object-src 'none'"

    [nonce] = Regex.run(~r/script-src 'self' 'nonce-([^']+)'/, csp, capture: :all_but_first)
    assert byte_size(nonce) > 0

    # Cloudflare Turnstile must be allowed to load its script and iframe, or
    # /register can never collect a token (see put_content_security_policy/2).
    assert csp =~ "script-src 'self' 'nonce-#{nonce}' https://challenges.cloudflare.com"
    assert csp =~ "frame-src https://challenges.cloudflare.com"
    assert csp =~ "img-src 'self' https: data:"
  end

  test "the heartbeat ping pipeline (third-party cron pings) is not gated by CSRF", %{conn: conn} do
    conn = post(conn, "/h/does-not-exist")

    assert conn.status == 404
  end
end
