# ZuTalk 0.8.1

Filing to a city's archive now shows where each recording stands, stops
offering events the city has deleted, and copes with a city server that is
briefly out of reach.

ZuTalk requires macOS 12.5 or later.

## Filing to a city's archive

- **Each recording shows its filing status.** A recording's page and the
  recording lists now say whether it was filed, is being sent, is waiting to
  be retried, failed, was changed since it was filed, or was withdrawn, and
  offer the next step. Settings › City lists every recording you assigned
  to an event with the same wording, and the sidebar mentions it when
  something is still waiting or didn't go through.
- **Events deleted in the city are no longer offered.** ZuTalk listed events
  a coordinator or curator had deleted, and a recording filed under one was
  shown nowhere in the city. They are left out now. If an event is deleted
  after you chose it, ZuTalk tells you instead of filing; if it is deleted
  after you filed, the recording is marked so that "filed" here never
  disagrees with what the city shows.
- **"No network" no longer appears when you are online.** When the city's
  server couldn't be reached for a moment, ZuTalk said this Mac was offline.
  It now says the city's server couldn't be reached, tries again by itself,
  and retries waiting recordings every two minutes.
- **The event list loads faster.** It is fetched compressed and without
  data ZuTalk doesn't use, about a third of the previous size.
