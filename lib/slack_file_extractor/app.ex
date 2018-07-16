defmodule SlackFileExtractor.Application do
  @moduledoc false
  use Application

  def start(_type, _args) do
    File.mkdir_p!(SlackFileExtractor.cache_dir())

    :ets.new(SlackFileExtractor.CacheSemaphores, [:set, :public, :named_table, write_concurrency: true, read_concurrency: true])

    Supervisor.start_link([], strategy: :one_for_one, name: SlackFileExtractor.Supervisor)
  end
end
