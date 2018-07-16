defmodule SlackFileExtractor.Job do
  # use HTTPoison.Base
  require Logger
  alias DurableWorkflow.Session

  @lock_table SlackFileExtractor.CacheSemaphores

  def init(_, %Session{restored: true, state: state}), do: state
  def init({opts, []}, session) do
    source_path = Keyword.get(opts, :source, Path.join(File.cwd!(), "export_archive"))

    files_dir = Path.join(source_path, "_files")
    toc_path = Path.join(session.path, "toc.etfs")

    %{
      source_path: source_path,
      files_dir: files_dir,
      toc_path: toc_path
    }
  end

  def handle_step(:start, state) do
    channels_path = Path.join(state.source_path, "channels.json")

    unless File.exists?(channels_path) do
      raise "Invalid export archive: '#{state.source_path}'"
    end

    channels = File.read!(channels_path)
    |> Jason.decode!(keys: :atoms)

    channel_dirs = Enum.map channels, &Path.join(state.source_path, &1.name)

    log_file_paths = Enum.flat_map channel_dirs, fn dir ->
      Path.wildcard(Path.join(dir, "*.json"))
    end

    state = Map.put_new(state, :log_file_paths, log_file_paths)

    {:transition, :create_toc, state}
  end

  def handle_step(:create_toc, state) do
    Logger.info "Scraping #{length(state.log_file_paths)} archive segments for referenced URLs:"

    state.log_file_paths
    |> Stream.flat_map(fn log_file_path ->
      channel_name = log_file_path |> Path.dirname() |> Path.basename()

      events_with_urls = log_file_path
      |> File.read!
      |> Jason.decode!(keys: :atoms)
      |> Enum.flat_map(fn event ->
        event_dt = event.ts
        |> String.replace(".", "")
        |> String.to_integer
        |> DateTime.from_unix!(:microsecond)

        Enum.map maybe_urls_from_event(event), fn uri ->
          %{channel: channel_name, timestamp: event_dt, uri: uri}
        end
      end)

      relative_log_file_path = Path.relative_to(log_file_path, state.source_path)
      Logger.info("  - '#{relative_log_file_path}': #{length(events_with_urls)} URLs found")

      events_with_urls
    end)
    |> Enum.into(ETFs.stream!(state.toc_path))

    {:transition, :crawl_urls, state}
  end

  def handle_step(:crawl_urls, state) do
    Logger.info("Scraping referenced URLs into cache:")

    ETFs.stream!(state.toc_path)
    |> Task.async_stream(fn event_with_url ->
      cache_url!(event_with_url)
    end, timeout: :infinity, ordered: false)
    |> Stream.run()

    {:transition, :expose_downloads_as_files, state}
  end

  def handle_step(:expose_downloads_as_files, state) do
    File.mkdir_p!(state.files_dir)

    toc = ETFs.stream!(state.toc_path)
    uri_count = Enum.count(toc)

    progress_format = [
      bar: "█",
      blank: "▒",
      bar_color: IO.ANSI.green,
      blank_color: IO.ANSI.green,
      left: "Exposing downloaded URLs: |"
    ]

    toc
    |> Stream.with_index()
    |> Enum.each(fn {event_with_url, i} ->
      expose_url_as_file!(event_with_url, state)
      ProgressBar.render(i + 1, uri_count, progress_format)
    end)

    {:done, state}
  end


  @hypertext_exts MapSet.new(["", ".html", ".htm", ".asp", ".php", ".cgi", ".jsp"])

  defp maybe_urls_from_event(%{file: %{url_private_download: uri}}), do: [uri]
  defp maybe_urls_from_event(%{attachments: atts}) do
    Enum.flat_map atts, fn
      %{image_url: uri} -> [uri]
      _ -> []
    end
  end
  defp maybe_urls_from_event(%{text: text}) do
    Regex.scan(~r/<(https?:[^>]+)>/, text, capture: :all_but_first)
    |> Enum.flat_map(fn [uri] ->
      doc_ext = case URI.parse(uri).path do
        str when is_binary(str) ->
          str |> Path.extname() |> String.downcase()
        nil ->
          ""
      end

      case MapSet.member?(@hypertext_exts, doc_ext) do
        true  -> []
        false -> [uri]
      end
    end)
  end

  def get_or_create_cache_entry(%{uri: uri}) do
    hash = :crypto.hash(:md5, uri) |> Base.encode16(case: :lower)

    shard_path = Path.join(SlackFileExtractor.cache_dir(), String.slice(hash, 0, 3))
    File.mkdir_p!(shard_path)

    raw_path = Path.join(shard_path, hash)

    uri_path = raw_path <> ".uri"
    status_path = raw_path <> ".status"
    body_path = raw_path <> ".body"

    unless File.exists?(uri_path) do
      File.write!(uri_path, uri)
    end

    status = if File.exists?(status_path) do
      error = File.read!(status_path)
      |> :erlang.binary_to_term()

      {:error, error}
    else
      if File.exists?(body_path) do
        :downloaded
      else
        :new
      end
    end

    %{
      uri: uri,
      raw_path: raw_path,

      status: status,

      uri_path: uri_path,
      status_path: status_path,
      body_path: body_path
    }
  end

  def cache_url!(%{uri: uri} = event) do
    cache_entry = get_or_create_cache_entry(event)

    case cache_entry.status do
      :downloaded ->
        Logger.debug("already downloaded: '#{uri}'")
        :ok

      {:error, e} ->
        Logger.debug("has error: '#{uri}' => '#{inspect e}'")
        {:error, e}

      :new ->
        case :ets.update_counter(@lock_table, uri, {2, 1}, {uri, 0}) do
          1 ->
            result = really_cache_url!(cache_entry)
            :ets.update_counter(@lock_table, uri, {2, -1}, {uri, 0})
            result

          n when n > 1 ->
            :ets.update_counter(@lock_table, uri, {2, -1}, {uri, 0})
            {:error, :contended}
        end
    end
  end

  defp really_cache_url!(cache_entry) do
    Temp.track!()

    tmpfile_path = Temp.path!("slack_file_extractor")

    File.touch!(tmpfile_path)
    io_device = File.open!(tmpfile_path, [:append])

    case really_cache_url_head!(cache_entry, io_device, cache_entry.uri) do
      :ok ->
        resp_size = File.stat!(tmpfile_path).size
        Logger.info("  - retrieved #{cache_entry.uri}: #{resp_size} bytes")
        File.ln!(tmpfile_path, cache_entry.body_path)
        :downloaded

      {:error, detail} ->
        Logger.error(" - #{inspect detail} for '#{cache_entry.uri}'")
        File.write!(cache_entry.status_path, :erlang.term_to_binary(detail))
        {:error, detail}
    end
  end

  def really_cache_url_head!(cache_entry, io_device, effective_uri) do
    case HTTPoison.get(effective_uri, %{}, stream_to: self(), timeout: 50_000, recv_timeout: 50_000, follow_redirect: true, hackney: [:insecure, pool: :default]) do
      {:ok, %HTTPoison.AsyncResponse{id: ref}} ->
        really_cache_url_chunk!(cache_entry, io_device, effective_uri, ref)

      {:error, e} ->
        {:error, e}
    end
  end

  defp really_cache_url_chunk!(cache_entry, io_device, effective_uri, ref) do
    receive do
      %HTTPoison.AsyncHeaders{id: ^ref} ->
        really_cache_url_chunk!(cache_entry, io_device, effective_uri, ref)

      %HTTPoison.AsyncStatus{id: ^ref, code: n} when n < 400 ->
        really_cache_url_chunk!(cache_entry, io_device, effective_uri, ref)

      %HTTPoison.AsyncStatus{id: ^ref, code: n} when n >= 400 ->
        File.close(io_device)
        {:error, {:http_status, n}}

      %HTTPoison.AsyncRedirect{id: ^ref, to: new_uri} ->
        case :file.position(io_device, :cur) do
          {:ok, 0} ->
            case parse_redirect_location(new_uri, effective_uri) do
              nil ->
                File.close(io_device)
                {:error, {:invalid_redirect, new_uri}}
              new_abs_uri ->
                really_cache_url_head!(cache_entry, io_device, new_abs_uri)
            end

          {:ok, _} ->
            raise RuntimeError, "redirect after chunks delivered"
        end

      %HTTPoison.AsyncChunk{chunk: body_chunk, id: ^ref} ->
        IO.binwrite(io_device, body_chunk)
        really_cache_url_chunk!(cache_entry, io_device, effective_uri, ref)

      %HTTPoison.AsyncEnd{id: ^ref} ->
        File.close(io_device)
        :ok

      other ->
        File.close(io_device)
        {:error, other}
    end
  end

  def parse_redirect_location(("http://" <> _) = new_uri, old_uri), do: parse_abs_redirect(new_uri, old_uri)
  def parse_redirect_location(("https://" <> _) = new_uri, old_uri), do: parse_abs_redirect(new_uri, old_uri)
  def parse_redirect_location(("//" <> _) = new_uri, old_uri), do: parse_abs_redirect(new_uri, old_uri)

  def parse_redirect_location(new_uri, old_uri) do
    old = URI.parse(old_uri)
    new = URI.parse(new_uri) |> Map.from_struct() |> Enum.filter(fn {_, v} -> v != nil end)

    new_path = case {old.path, new[:path]} do
      {old_path, nil} -> old_path

      {_, ("/" <> _) = path} ->
        path

      {nil, rel_path} ->
        "/" <> rel_path

      {old_abs_path, rel_path} ->
        Path.join(old_abs_path, rel_path) |> Path.expand()
    end

    new = Keyword.put(new, :path, new_path)

    struct(old, new)
  end

  defp parse_abs_redirect(new_uri, old_uri) do
    new = URI.parse(new_uri)

    new = case new.scheme do
      nil ->
        struct(new, scheme: URI.parse(old_uri).scheme)

      scheme when is_binary(scheme) ->
        new
    end

    case new.host do
      nil -> nil
      "" -> nil
      _host -> URI.to_string(new)
    end
  end

  def expose_url_as_file!(%{channel: channel_name, timestamp: event_dt, uri: uri} = event, state) do
    cache_entry = get_or_create_cache_entry(event)

    case cache_entry.status do
      {:error, _} ->
        # maybe print the error
        :ok

      :new ->
        raise RuntimeError, "uri '#{uri}' missing cache entry '#{cache_entry.raw_path}'"

      :downloaded ->
        uri_path = URI.parse(uri).path

        uri_filename = Path.basename(uri_path)
        uri_rootname = Path.rootname(uri_filename)
        uri_extname = Path.extname(uri_filename)

        formatted_ts = Timex.format!(event_dt, "{YYYY}-{0M}-{0D} {0h24}:{0m}:{0s}")

        expose_filename = "#{uri_rootname} (#{channel_name} on #{formatted_ts})#{uri_extname}"

        expose_path = Path.join(state.files_dir, expose_filename)

        unless File.exists?(expose_path) do
          File.ln!(cache_entry.body_path, expose_path)
          Logger.debug("  - ln '#{expose_path}'")
        end
    end
  end
end
