# Drives the real acquisition path against the running dev database:
# organic landing -> attributed signup -> project -> monitor -> real heartbeat
# ping over HTTP -> the funnel report a human would actually read.
#
# Uses real Ash actions and a real HTTP ping, not test fixtures.
alias Alplus.{Growth, Scope}
alias Alplus.Monitoring.{HeartbeatConfig, Monitor}

email = "e2e-#{System.unique_integer([:positive])}@example.com"

# Registration itself is deliberately not scripted: `:register_with_password`
# requires a real Turnstile token, and that gate working is correct behaviour
# rather than an obstacle to route around. The browser path is covered by
# `Alplus.GrowthAttributionTest`, which drives the actual LiveView form.
#
# Everything after signup, which is what this script exists to verify, is the
# real path: real Ash actions, a real heartbeat ping over HTTP, and the real
# funnel report.
user =
  Ash.Seed.seed!(Alplus.Accounts.User, %{
    email: email,
    hashed_password: Bcrypt.hash_pwd_salt("a-str0ng-passphrase"),
    confirmed_at: DateTime.utc_now()
  })

# The visitor landed on the Kubernetes guide from Google.
:ok =
  Growth.record_signup_attribution(user.id, %{
    "landing_page" => "/guides/kubernetes-cronjob-heartbeat",
    "referrer_host" => "www.google.com",
    "utm" => %{}
  })

scope = Scope.for_user(user.id)
org = Ash.create!(Alplus.Orgs.Organization, %{name: "E2E Org"}, action: :create, actor: scope)
{:ok, owner} = Alplus.Orgs.build_scope(scope, org.id)

project =
  Ash.create!(Alplus.Projects.Project, %{org_id: org.id, name: "E2E Project"},
    action: :create,
    actor: owner
  )

pscope = Scope.put_project(owner, project.id)

monitor =
  Ash.create!(
    Monitor,
    %{org_id: org.id, project_id: project.id, type: "heartbeat", name: "Nightly backup"},
    action: :create,
    actor: pscope
  )

config =
  Ash.create!(
    HeartbeatConfig,
    %{monitor_id: monitor.id, org_id: org.id, grace_period_seconds: 60, interval_seconds: 300},
    action: :issue,
    actor: pscope
  )

token = Ash.Resource.get_metadata(config, :heartbeat_token)
IO.puts("TOKEN=#{token}")
IO.puts("MONITOR=#{monitor.id}")
