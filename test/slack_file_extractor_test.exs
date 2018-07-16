defmodule SlackFileExtractorTest do
  use ExUnit.Case
  doctest SlackFileExtractor

  test "greets the world" do
    assert SlackFileExtractor.hello() == :world
  end
end
