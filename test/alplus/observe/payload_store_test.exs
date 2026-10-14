defmodule Alplus.Observe.PayloadStoreAdaptersTest do
  use ExUnit.Case, async: false

  alias Alplus.Observe.PayloadStore.{Local, S3, Unconfigured}

  test "unconfigured adapter rejects put and get" do
    assert {:error, :payload_store_unconfigured} = Unconfigured.put("k", "v")
    assert {:error, :payload_store_unconfigured} = Unconfigured.get("k")
  end

  test "local adapter writes, reads, and 404s" do
    key = "events/proj/cov-#{System.unique_integer([:positive])}.json"
    assert :ok = Local.put(key, ~s({"ok":true}))
    assert {:ok, ~s({"ok":true})} = Local.get(key)
    assert {:error, :not_found} = Local.get("events/missing.json")
  end

  test "s3 adapter surfaces request failures" do
    snapshot =
      snapshot_env([
        {:alplus, :observe_payload_bucket},
        {:ex_aws, :access_key_id},
        {:ex_aws, :secret_access_key}
      ])

    on_exit(fn -> restore_env(snapshot) end)

    Application.put_env(:alplus, :observe_payload_bucket, "alplus-missing-bucket")
    Application.put_env(:ex_aws, :access_key_id, "test")
    Application.put_env(:ex_aws, :secret_access_key, "test")

    assert {:error, {:s3_put_failed, _}} = S3.put("k", "v")
    assert {:error, _} = S3.get("k")
  end

  test "s3 put sends AES256 encryption by default" do
    configure_s3_http_client(self())
    Application.delete_env(:alplus, :observe_payload_s3_server_side_encryption)

    assert :ok = S3.put("key", "payload")
    assert_receive {:ex_aws_request, :put, _url, "payload", headers}
    assert {"x-amz-server-side-encryption", "AES256"} in headers
  end

  test "s3 put omits encryption when configured for R2" do
    configure_s3_http_client(self())
    Application.put_env(:alplus, :observe_payload_s3_server_side_encryption, nil)

    assert :ok = S3.put("key", "payload")
    assert_receive {:ex_aws_request, :put, _url, "payload", headers}
    refute Enum.any?(headers, fn {name, _value} -> name == "x-amz-server-side-encryption" end)
  end

  defp configure_s3_http_client(test_pid) do
    snapshot =
      snapshot_env([
        {:alplus, :observe_payload_bucket},
        {:alplus, :observe_payload_s3_server_side_encryption},
        {:ex_aws, :http_client},
        {:ex_aws, :test_pid},
        {:ex_aws, :access_key_id},
        {:ex_aws, :secret_access_key},
        {:ex_aws, :region}
      ])

    Application.put_env(:alplus, :observe_payload_bucket, "test-bucket")
    Application.put_env(:alplus, :observe_payload_s3_server_side_encryption, "AES256")
    Application.put_env(:ex_aws, :http_client, Alplus.ExAwsHTTPClientFake)
    Application.put_env(:ex_aws, :test_pid, test_pid)
    Application.put_env(:ex_aws, :access_key_id, "test")
    Application.put_env(:ex_aws, :secret_access_key, "test")
    Application.put_env(:ex_aws, :region, "us-east-1")

    on_exit(fn -> restore_env(snapshot) end)
  end

  defp snapshot_env(keys) do
    Map.new(keys, fn {app, key} -> {{app, key}, Application.fetch_env(app, key)} end)
  end

  defp restore_env(snapshot) do
    Enum.each(snapshot, fn {{app, key}, result} ->
      case result do
        {:ok, value} -> Application.put_env(app, key, value)
        :error -> Application.delete_env(app, key)
      end
    end)
  end
end
