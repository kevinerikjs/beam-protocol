# Contributing

Protocol changes affect independently installed clients and hosts. Start with an issue for any change to bytes on the wire.

Keep changes additive where possible. New JSON fields must be optional, new behavior must be capability-gated, and existing packet IDs, header lengths, and field meanings must not change.

Run `swift test` before opening a pull request. Add a fixed-byte fixture when a binary layout changes and a decoding fixture when a JSON message changes.
