defmodule Alplus.Growth.SignupAttribution do
  @moduledoc """
  How one account arrived: the landing page that earned the signup, the
  referring host, and any UTM tags, captured at registration.

  One row per user, written once and never updated, so the record cannot be
  rewritten by later activity. Not tenant-owned: it describes acquisition,
  which happens before an organization exists.

  Privacy: no IP address, no user agent, no full referring URL, and no
  cross-site identifier. `AlplusWeb.Plugs.AcquisitionAttribution` reduces
  the referrer to a host before it ever reaches this resource, so the page
  someone came from is recorded as "google.com", not as a URL carrying
  their search terms.

  Reporting reads this joined to activation events, which is what turns
  "we published a cron guide" into "cron content produced N activated
  organizations".
  """

  use Ash.Resource,
    otp_app: :alplus,
    domain: Alplus.Growth,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "growth_signup_attributions"
    repo Alplus.Repo

    custom_statements do
      statement :landing_page_length_check do
        up "ALTER TABLE growth_signup_attributions ADD CONSTRAINT growth_signup_attributions_landing_page_length_check CHECK (octet_length(landing_page) <= 300)"

        down "ALTER TABLE growth_signup_attributions DROP CONSTRAINT growth_signup_attributions_landing_page_length_check"
      end

      statement :referrer_host_length_check do
        up "ALTER TABLE growth_signup_attributions ADD CONSTRAINT growth_signup_attributions_referrer_host_length_check CHECK (referrer_host IS NULL OR octet_length(referrer_host) <= 200)"

        down "ALTER TABLE growth_signup_attributions DROP CONSTRAINT growth_signup_attributions_referrer_host_length_check"
      end
    end
  end

  actions do
    defaults [:read]

    create :record do
      accept [:user_id, :landing_page, :referrer_host, :utm, :content_cluster, :first_seen_at]

      # A user signs up once. An upsert rather than an error keeps a
      # replayed registration POST from failing the request: acquisition
      # reporting must never be able to break a signup.
      upsert? true
      upsert_identity :unique_user
    end
  end

  # Read is staff-only reporting for now, so no policy authorizes it and
  # every caller must pass `authorize?: false` deliberately, exactly like
  # `Alplus.Content` writes. Nothing in the console reads this yet.
  policies do
    policy always() do
      forbid_if always()
    end
  end

  attributes do
    attribute :id, Alplus.Id do
      constraints prefix: "acq"
      public? true
      writable? false
      primary_key? true
      allow_nil? false
      default fn -> Alplus.Id.generate("acq") end
    end

    attribute :user_id, :string do
      allow_nil? false
      public? true
      constraints max_length: 50
    end

    # The first public page of the session, not the page the form was on.
    attribute :landing_page, :string do
      allow_nil? false
      public? true
      constraints max_length: 300
    end

    attribute :referrer_host, :string do
      public? true
      constraints max_length: 200
    end

    attribute :utm, :map do
      public? true
      default %{}
    end

    # Which content cluster the landing page belongs to, resolved at write
    # time from the path. Stored rather than derived on read so a later URL
    # change cannot silently rewrite historical attribution.
    attribute :content_cluster, :string do
      allow_nil? false
      public? true
      default "other"
      constraints max_length: 50
    end

    attribute :first_seen_at, :utc_datetime_usec do
      public? true
    end

    create_timestamp :inserted_at
  end

  identities do
    identity :unique_user, [:user_id]
  end
end
