defmodule Alplus.Accounts.User do
  @moduledoc """
  A person who can sign in to PostDeploy and hold membership in one or more orgs.
  """

  use Ash.Resource,
    otp_app: :alplus,
    domain: Alplus.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAuthentication]

  authentication do
    add_ons do
      log_out_everywhere do
        apply_on_password_change? true
      end

      confirmation :confirm_new_user do
        monitor_fields [:email]
        confirm_on_create? true
        confirm_on_update? false
        require_interaction? true
        confirmed_at_field :confirmed_at
        # No :sign_in_with_magic_link here — PostDeploy has no magic-link strategy.
        auto_confirm_actions [:reset_password_with_token]
        sender Alplus.Accounts.User.Senders.SendNewUserConfirmationEmail
      end

      # Profile email changes (`:update_profile`) re-verify the new address
      # before it becomes the login identity — a *second*, independent
      # confirmation add-on, not `confirm_new_user` reconfigured in place.
      # `confirm_new_user` shares its `confirmed_at_field` with the
      # `confirmed_at` `AlplusWeb.LiveUserAuth` gates every `/dashboard/*`
      # mount on; `ConfirmationHookChange.nil_confirmed_at_field/2`
      # unconditionally clears that field whenever it inhibits an update to
      # a monitored field. Reusing `confirm_new_user` for email changes
      # would sign the user out of every org the moment they requested a
      # change, before the new address was ever confirmed — the opposite of
      # "keep signing in with the old email until the new one is verified."
      # A dedicated `confirmed_at_field: :email_confirmed_at` keeps that
      # bookkeeping off the login gate entirely.
      confirmation :confirm_email_change do
        monitor_fields [:email]
        confirm_on_create? false
        confirm_on_update? true
        require_interaction? true
        confirmed_at_field :email_confirmed_at
        # Both add-ons default `confirm_action_name` to the same `:confirm`
        # atom (a `defstruct` default, not `nil` — the "fall back to the
        # add-on's own name" branch only fires on a literal `nil`), so a
        # second confirmation add-on needs this set explicitly or its
        # generated `update :confirm` action collides with
        # `confirm_new_user`'s.
        confirm_action_name :confirm_email_change
        sender Alplus.Accounts.User.Senders.SendEmailChangeConfirmationEmail
      end
    end

    tokens do
      enabled? true
      token_resource Alplus.Accounts.Token
      signing_secret Alplus.Secrets
      store_all_tokens? true
      require_token_presence_for_authentication? true
    end

    strategies do
      password :password do
        identity_field :email
        hash_provider AshAuthentication.BcryptProvider
        # Lockout and success/failure counting happen at the web layer
        # (AlplusWeb.Router's `enforce_login_lockout` plug and
        # AlplusWeb.AuthController's success/failure callbacks), which
        # requires every sign-in to be a real HTTP request rather than a
        # direct Ash call from inside the sign-in LiveView.
        sign_in_tokens_enabled? false

        resettable do
          sender Alplus.Accounts.User.Senders.SendPasswordResetEmail
          # these configurations will be the default in a future release
          password_reset_action_name :reset_password_with_token
          request_password_reset_action_name :request_password_reset_token
        end
      end

      remember_me :remember_me
    end
  end

  postgres do
    table "users"
    repo Alplus.Repo

    custom_statements do
      statement :name_length_check do
        up "ALTER TABLE users ADD CONSTRAINT users_name_length_check CHECK (name IS NULL OR octet_length(btrim(name)) BETWEEN 1 AND 120)"
        down "ALTER TABLE users DROP CONSTRAINT users_name_length_check"
      end

      # `email` is `citext` (migration 20260810171456): comparison is
      # already case-insensitive at the DB level, so a `email = lower(...)`
      # check would be trivially true regardless of stored casing. The
      # meaningful DB-level invariant `citext` does *not* give for free is
      # "no leading/trailing whitespace" — `Alplus.Accounts.User.Changes
      # .NormalizeEmail` downcases and trims at the Ash layer; this backs
      # the trim half with a real constraint.
      statement :email_normalized_check do
        up "ALTER TABLE users ADD CONSTRAINT users_email_normalized_check CHECK (email::text = btrim(email::text) AND octet_length(email::text) <= 320)"
        down "ALTER TABLE users DROP CONSTRAINT users_email_normalized_check"
      end
    end
  end

  actions do
    defaults [:read]

    read :get_by_subject do
      description "Get a user by the subject claim in a JWT"
      argument :subject, :string, allow_nil?: false
      get? true
      prepare AshAuthentication.Preparations.FilterBySubject
    end

    update :change_password do
      require_atomic? false
      accept []
      argument :current_password, :string, sensitive?: true, allow_nil?: false

      argument :password, :string,
        sensitive?: true,
        allow_nil?: false,
        constraints: [min_length: 8]

      argument :password_confirmation, :string, sensitive?: true, allow_nil?: false

      validate confirm(:password, :password_confirmation)

      validate {AshAuthentication.Strategy.Password.PasswordValidation,
                strategy_name: :password, password_argument: :current_password}

      validate {Alplus.Accounts.Validations.StrongPassword, argument: :password}
      validate {Alplus.Accounts.Validations.NotPwned, argument: :password}

      change {AshAuthentication.Strategy.Password.HashPasswordChange, strategy_name: :password}
    end

    read :sign_in_with_password do
      description "Attempt to sign in using a email and password."
      get? true

      argument :email, :ci_string do
        description "The email to use for retrieving the user."
        allow_nil? false
      end

      argument :password, :string do
        description "The password to check for the matching user."
        allow_nil? false
        sensitive? true
      end

      prepare AshAuthentication.Strategy.Password.SignInPreparation

      metadata :token, :string do
        description "A JWT that can be used to authenticate the user."
        allow_nil? false
      end
    end

    read :sign_in_with_token do
      description "Attempt to sign in using a short-lived sign in token."
      get? true

      argument :token, :string do
        description "The short-lived sign in token."
        allow_nil? false
        sensitive? true
      end

      prepare AshAuthentication.Strategy.Password.SignInWithTokenPreparation

      metadata :token, :string do
        description "A JWT that can be used to authenticate the user."
        allow_nil? false
      end
    end

    create :register_with_password do
      description "Register a new user with a email and password."

      argument :email, :ci_string do
        allow_nil? false
      end

      argument :password, :string do
        description "The proposed password for the user, in plain text."
        allow_nil? false
        constraints min_length: 8
        sensitive? true
      end

      argument :password_confirmation, :string do
        description "The proposed password for the user (again), in plain text."
        allow_nil? false
        sensitive? true
      end

      argument :turnstile_token, :string do
        description "The Cloudflare Turnstile challenge response from the sign-up form."
        allow_nil? true
        sensitive? true
      end

      change set_attribute(:email, arg(:email))

      change AshAuthentication.Strategy.Password.HashPasswordChange

      change AshAuthentication.GenerateTokenChange

      # Blocks registration while sign-ups are disabled (SIGNUPS_ENABLED).
      # Runs first so a disabled gate skips the network calls below.
      validate Alplus.Accounts.Validations.SignupsEnabled

      # Verifies the Cloudflare Turnstile challenge server-side. This must
      # be a before_action change, not a validation: a Turnstile token is
      # single-use, and Ash validations also run on AshPhoenix.Form's
      # phx-change `validate`, which would spend the token before submit.
      change {Alplus.Accounts.Changes.VerifyTurnstile, argument: :turnstile_token}

      # validates that the password matches the confirmation
      validate AshAuthentication.Strategy.Password.PasswordConfirmationValidation

      validate {Alplus.Accounts.Validations.StrongPassword, argument: :password}
      validate {Alplus.Accounts.Validations.NotPwned, argument: :password}

      metadata :token, :string do
        description "A JWT that can be used to authenticate the user."
        allow_nil? false
      end
    end

    action :request_password_reset_token do
      description "Send password reset instructions to a user if they exist."

      argument :email, :ci_string do
        allow_nil? false
      end

      argument :turnstile_token, :string do
        description "The Cloudflare Turnstile challenge response from the reset form."
        allow_nil? true
        sensitive? true
      end

      # creates a reset token and invokes the relevant senders
      run {Alplus.Accounts.Actions.RequestPasswordReset, action: :get_by_email}
    end

    read :get_by_email do
      description "Looks up a user by their email"
      get_by :email
    end

    update :mark_confirmed do
      description """
      Internal: sets confirmed_at directly, bypassing the emailed-token
      flow. Never expose to actors directly. Used by test fixtures that
      need a confirmed session without driving the real confirm link.
      """

      accept []
      change set_attribute(:confirmed_at, &DateTime.utc_now/0)
    end

    update :update_profile do
      description """
      A user updates their own display name (immediate) or requests an
      email change. `:name` applies right away. `:email`, a
      `confirm_email_change` monitored field with the add-on's default
      `inhibit_updates?: true`, is staged instead of applied: the
      confirmation hook clears the pending attribute change before persist
      and emails a re-verification link to the new address (`Alplus.Accounts
      .User.Senders.SendEmailChangeConfirmationEmail`). The login email
      (and `confirmed_at`) stay untouched until that link is confirmed via
      the `:confirm_email_change` action. A duplicate email is rejected by
      the same hook's identity check (`has already been taken`), before any
      write is attempted.
      """

      require_atomic? false
      accept [:name, :email]

      change Alplus.Accounts.User.Changes.NormalizeEmail
    end

    update :reset_password_with_token do
      argument :reset_token, :string do
        allow_nil? false
        sensitive? true
      end

      argument :password, :string do
        description "The proposed password for the user, in plain text."
        allow_nil? false
        constraints min_length: 8
        sensitive? true
      end

      argument :password_confirmation, :string do
        description "The proposed password for the user (again), in plain text."
        allow_nil? false
        sensitive? true
      end

      # validates the provided reset token
      validate AshAuthentication.Strategy.Password.ResetTokenValidation

      # validates that the password matches the confirmation
      validate AshAuthentication.Strategy.Password.PasswordConfirmationValidation

      validate {Alplus.Accounts.Validations.StrongPassword, argument: :password}
      validate {Alplus.Accounts.Validations.NotPwned, argument: :password}

      # Hashes the provided password
      change AshAuthentication.Strategy.Password.HashPasswordChange

      # Generates an authentication token for the user
      change AshAuthentication.GenerateTokenChange
    end
  end

  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if always()
    end

    # A console page (e.g. `AlplusWeb.TeamLive`) loads a fellow member's
    # `email` off `Membership.user` to render the team list — allow reading
    # a user row for the actor's own id, or for any user who shares a
    # membership in the actor's current org (ARCHITECTURE.md §4: repeats
    # the tenant predicate at the query, via `Alplus.Scope.org_id`, rather
    # than trusting the caller's join).
    policy action_type(:read) do
      authorize_if expr(id == ^actor(:user_id))

      authorize_if expr(
                     exists(
                       memberships,
                       org_id == ^actor(:org_id) and
                         exists(organization.memberships, user_id == ^actor(:user_id))
                     )
                   )
    end

    # A user edits only their own profile — never another user's, even a
    # fellow org member's (ARCHITECTURE.md §4: the tenant predicate is
    # re-checked at the query/action itself). No org role is involved.
    policy action(:update_profile) do
      authorize_if expr(id == ^actor(:user_id))
    end
  end

  attributes do
    attribute :id, Alplus.Id do
      constraints prefix: "user"
      public? true
      writable? false
      primary_key? true
      allow_nil? false
      default fn -> Alplus.Id.generate("user") end
    end

    attribute :email, :ci_string do
      allow_nil? false
      public? true
    end

    attribute :name, :string do
      description "Display name shown in the console instead of the raw email. Optional."
      allow_nil? true
      public? true
      constraints max_length: 120, trim?: true, allow_empty?: false
    end

    attribute :hashed_password, :string do
      allow_nil? false
      sensitive? true
    end

    attribute :confirmed_at, :utc_datetime_usec
  end

  relationships do
    has_many :memberships, Alplus.Orgs.Membership do
      destination_attribute :user_id
    end
  end

  identities do
    identity :unique_email, [:email]
  end
end
