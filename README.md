# SlackFileExtractor

For when you want to delete your Slack team.

## Building

```bash
$ git clone https://github.com/tsutsu/slack_file_extractor
$ cd slack_file_extractor
$ mix do deps.get, compile
```

## Usage

To start a new session:

```bash
$ mix scrape --source "path/to/My\ Slack\ export\ Jan\ 01\ 2015\ -\ Jul\ 15\ 2018"
```

To continue an interrupted session:

```bash
$ mix scrape --session last
```

The HTTP client used by SlackFileExtractor maintains a never-purged response cache in `./cache.bundle`. Delete it after you're done, or keep it if you plan on running the extractor against a later archive dump of the same workspace!

Downloads are hard-linked from the cache directory to their final locations, and so the cache directory and export-archive directory must be on the same volume.
