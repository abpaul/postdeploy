defmodule Alplus.Notifications.ChannelTest do
  use ExUnit.Case, async: true

  alias Alplus.Notifications.Channel

  test "channel config is an AshCloak calculation over a private sensitive ciphertext column" do
    encrypted_config = Ash.Resource.Info.attribute(Channel, :encrypted_config)
    config = Ash.Resource.Info.calculation(Channel, :config)

    assert encrypted_config.type == Ash.Type.Binary
    assert encrypted_config.public? == false
    assert encrypted_config.sensitive? == true
    assert config.filterable? == false
    assert config.sortable? == false
    assert config.sensitive? == true
  end
end

defmodule Alplus.Notifications.PresentationTest do
  use Alplus.DataCase, async: true

  import ExUnit.CaptureLog
  import Alplus.OrgsFixtures

  alias Alplus.Notifications.{Channel}

  test "channel presentation masks encrypted destination config" do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))
    destination = "hidden-#{System.unique_integer([:positive])}@example.test"

    assert {:ok, _channel} =
             Alplus.Notifications.create_channel(
               %{
                 org_id: org.id,
                 type: "email",
                 name: "Operations",
                 config: %{"to" => destination}
               },
               owner_scope
             )

    assert {:ok, [presentation]} = Alplus.Notifications.list_channel_presentations(owner_scope)
    refute Map.has_key?(presentation, :config)
    assert presentation.destination == "h•••@example.test"
    refute presentation.destination =~ destination
  end

  test "channel settings reject an organization id outside the actor scope" do
    owner = user_fixture()
    {_org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))

    assert {:error, :scope_mismatch} =
             Alplus.Notifications.create_channel(
               %{org_id: "organization_other", type: "email", name: "Other", config: %{}},
               owner_scope
             )
  end

  test "channel action validates each destination type and parses HTTPS URLs" do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))

    assert {:error, %Ash.Error.Invalid{}} =
             Alplus.Notifications.create_channel(
               %{
                 org_id: org.id,
                 type: "webhook",
                 name: "Bad endpoint",
                 config: %{"url" => "http://hooks.example.test", "secret" => "short"}
               },
               owner_scope
             )

    assert {:error, %Ash.Error.Invalid{}} =
             Alplus.Notifications.create_channel(
               %{
                 org_id: org.id,
                 type: "telegram",
                 name: "Bad Telegram",
                 config: %{"bot_token" => "short", "chat_id" => "chat"}
               },
               owner_scope
             )

    secret = Base.encode16(:crypto.strong_rand_bytes(24), case: :lower)

    assert {:ok, channel} =
             Alplus.Notifications.create_channel(
               %{
                 org_id: org.id,
                 type: "webhook",
                 name: "Operations",
                 config: %{
                   "url" => "https://hooks.example.test/alerts?source=postdeploy",
                   "secret" => secret
                 }
               },
               owner_scope
             )

    assert {:ok, _updated} =
             Alplus.Notifications.update_channel(
               channel,
               %{
                 name: "Operations replacement",
                 config: %{
                   "url" => "https://hooks.example.test/replacement",
                   "secret" => Base.encode16(:crypto.strong_rand_bytes(24), case: :lower)
                 }
               },
               owner_scope
             )

    assert {:ok, [presentation]} = Alplus.Notifications.list_channel_presentations(owner_scope)
    refute Map.has_key?(presentation, :config)
    refute inspect(presentation) =~ secret
  end

  test "switching the default clears the previous row atomically" do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))

    attrs = fn name ->
      %{org_id: org.id, type: "email", name: name, config: %{"to" => "alerts@example.test"}}
    end

    assert {:ok, first} =
             Alplus.Notifications.create_channel(
               Map.put(attrs.("First"), :is_default, true),
               owner_scope
             )

    assert {:ok, second} = Alplus.Notifications.create_channel(attrs.("Second"), owner_scope)

    log =
      capture_log(fn ->
        assert {:ok, _} =
                 Alplus.Notifications.update_channel(second, %{is_default: true}, owner_scope)
      end)

    refute log =~ "Missed 1 notifications"

    assert %{is_default: false} = Ash.get!(Channel, first.id, actor: owner_scope)
    assert %{is_default: true} = Ash.get!(Channel, second.id, actor: owner_scope)
  end

  test "a failed default replacement restores the existing default" do
    owner = user_fixture()
    {org, owner_scope} = org_fixture(Alplus.Scope.for_user(owner.id))

    assert {:ok, first} =
             Alplus.Notifications.create_channel(
               %{
                 org_id: org.id,
                 type: "email",
                 name: "First",
                 config: %{"to" => "alerts@example.test"},
                 is_default: true
               },
               owner_scope
             )

    log =
      capture_log(fn ->
        assert {:error, %Ash.Error.Invalid{}} =
                 Alplus.Notifications.create_channel(
                   %{
                     org_id: org.id,
                     type: "email",
                     name: "",
                     config: %{"to" => "alerts@example.test"},
                     is_default: true
                   },
                   owner_scope
                 )
      end)

    refute log =~ "Missed 1 notifications"

    assert %{is_default: true} = Ash.get!(Channel, first.id, actor: owner_scope)
  end
end
