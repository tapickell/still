defmodule Still.ArtifactStore do
  @moduledoc "Content-addressed, verified controller artifacts. Existing objects are never overwritten."

  alias Still.Artifact.Archive
  alias Still.Artifact.Provider

  @doc "Downloads and verifies every submitted artifact, then publishes it under its SHA-256 digest."
  @spec stage(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def stage(application_name, version, opts)
      when is_binary(application_name) and is_binary(version) and is_list(opts) do
    if Archive.safe_component?(application_name) and Archive.safe_component?(version) do
      download_and_publish(application_name, opts)
    else
      {:error, :unsafe_artifact_identifier}
    end
  end

  defp download_and_publish(application_name, opts) do
    staging = artifacts_dir() <> ".staging"
    File.mkdir_p!(staging)
    File.chmod!(staging, 0o700)
    temporary = Path.join(staging, Ecto.UUID.generate() <> ".tar.gz")

    try do
      with {:ok, provider} <- Provider.for_type(Keyword.fetch!(opts, :source_type)),
           :ok <- provider.download(Keyword.fetch!(opts, :spec), temporary),
           {:ok, metadata} <- Archive.metadata(temporary),
           :ok <- Archive.validate(temporary) do
        publish(temporary, artifact_path(application_name, metadata.digest), metadata)
      end
    after
      File.rm(temporary)
    end
  end

  defp publish(temporary, destination, metadata) do
    File.mkdir_p!(Path.dirname(destination))

    # A hard link publishes complete bytes without rename's overwrite semantics.
    # Concurrent submissions of the same object verify the winner instead.
    with :ok <- File.chmod(temporary, 0o644),
         :ok <- publish_link(temporary, destination, metadata) do
      {:ok, destination}
    end
  end

  defp publish_link(temporary, destination, metadata) do
    case File.ln(temporary, destination) do
      {:error, :eexist} -> Archive.verify(destination, metadata)
      result -> result
    end
  end

  @doc "Returns the internal artifact URL for an application and immutable object digest."
  @spec artifact_url(String.t(), String.t()) :: String.t()
  def artifact_url(application_name, identifier)
      when is_binary(application_name) and is_binary(identifier) do
    validate_identifiers!(application_name, identifier)
    base = Application.fetch_env!(:still, :artifact_base_url)
    "#{base}/artifacts/#{application_name}/#{identifier}.tar.gz"
  end

  @doc "Returns a contained object path; also supports safe legacy identifiers for inspection."
  @spec artifact_path(String.t(), String.t()) :: String.t()
  def artifact_path(application_name, identifier)
      when is_binary(application_name) and is_binary(identifier) do
    validate_identifiers!(application_name, identifier)
    Path.join([artifacts_dir(), application_name, "#{identifier}.tar.gz"])
  end

  @doc "Conservatively retains all artifacts until remote active/previous references can be proven unused."
  @spec prune(String.t(), non_neg_integer() | nil) :: []
  def prune(application_name, retention \\ nil)
      when is_binary(application_name) and (is_nil(retention) or is_integer(retention)) do
    []
  end

  defp validate_identifiers!(application_name, identifier) do
    unless Archive.safe_component?(application_name) and Archive.safe_component?(identifier) do
      raise ArgumentError, "unsafe artifact identifier"
    end
  end

  defp artifacts_dir do
    Application.get_env(:still, :artifacts_dir, "/var/lib/still/artifacts")
  end
end
