# agent-ledger

[日本語](README.md) | [English](README.en.md)

When you hand long-running work to AI agents, every new session forgets what was going on. Status documents help for a while, then drift from reality because nobody updates them. agent-ledger is a tiny CLI, `j`, that keeps every record in **one append-only log** (`log.jsonl`). The current state is never stored; it is derived from the log each time.

- `j` is the only writer. IDs, timestamps and file locking are handled in one place, so several sessions can write at the same time without corrupting the log.
- Only events are recorded, in seven types: decision, money, ship, ask, answer, promise (a numeric prediction) and sys (a change to how things work).
- `j now` builds a re-entry view from the log: unanswered questions, recent decisions, this month's money, and which sessions are working on what. A fresh session reads it and picks up where things left off.

## Requirements

- Linux or macOS (uses `fcntl.flock`; Windows is not supported)
- Python 3.8+ (standard library only)

## Usage

Put `j` on your PATH or run it directly. The ledger is `log.jsonl` in the directory given by `J_ROOT` (the current directory if unset).

```sh
export J_ROOT=/path/to/myproject

j decision -p game 'Requester: "Go with title A". Title set to A'
j ask -p game "Is itch.io OK for the demo?"
j answer --re <ask-id> "itch.io is fine"
j money -1500 "server fee" --ref invoice.pdf
j ship -p game "Released the demo" --channel itch --ref https://example.itch.io/demo
j promise -p game "100+ downloads within 30 days"
j sys "Moved build steps into the Makefile"

j now            # re-entry view
j now -p game    # scope to one project (unassigned items, total money and all claims are always shown)
j money          # this month's money (use --month 2026-08 for another month)
j ships          # list of shipments
```

### Several sessions at once

- `j claim <project>` declares that you are working on a project, and `j release` frees it. It is a gentleman's agreement and does not block other writers. Claims disappear from the view after 4 hours.
- The writer is stored in the `who` field, chosen in this order: `J_WHO`, Cursor conversation ID, Codex thread ID, tmux session name, then `manual`. Check it with `j who`.

### Project list (optional)

If `J_ROOT/projects/<project>.md` files exist, `j now` lists each project with its last-modified date and last ship date. The contents are up to you; the intent is one short entry note per project.

### Currency

Amounts are signed integers, positive for income. Set the display unit with `J_UNIT` (default: 円).

## Example instructions for agents

Add something like this to your `AGENTS.md` or `CLAUDE.md`:

```markdown
- log.jsonl is the source of truth and j is the only writer. Record decisions, money, shipments, questions, answers, numeric predictions and process changes as one line each, when they happen.
- Keep the requester's words verbatim.
- Do not create status or summary documents; derive the current state from j now / j money / j ships.
- At the start of work, or after losing context, read j now first.
- Run j claim <project> before touching a project and j release when done.
```

## Rules built into the design

- `log.jsonl` is append-only. Lines are never edited or deleted; mistakes are corrected with a new line.
- `j <type> --help` only prints usage and never writes.
- Everything after `--` is taken literally as the text (e.g. `j sys -- --help -3000`).
- Empty entries and `answer` without `--re` are rejected.

## Tests

```sh
j selftest   # runs every command against an isolated ledger in a temp directory
```

The CLI's messages and view headings are in Japanese.

## License

MIT
