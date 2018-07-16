defmodule Mix.Tasks.Scrape do
  use DurableWorkflow.MixTask,
    shortdoc: "Scrapes files from a Slack archive export"

  def job_name, do: "scrape"
  def job, do: SlackFileExtractor.Job

  def switches do
    [
      source: :string
    ]
  end
end
