# The Claude side chat

The chat is optional. Reading notes, the outline, the shortcuts, document switching and push-to-talk transcription all work without Claude, with no account and no network. TalkMargin itself makes no network requests. The chat runs the Claude Code CLI on your Mac, and the CLI talks to the model provider.

TalkMargin is not an offline app as a whole: every Claude question goes over the network.

## What it needs

- The **Claude Code CLI** (`claude`), installed and logged in. TalkMargin looks for it in your login shell's `PATH`, then in `~/.local/bin`, `/opt/homebrew/bin` and `/usr/local/bin`. The minimum CLI version is unknown; the flags it uses are listed below.
- An **account or plan** that covers Claude Code use. Every question is one Claude Code turn, billed or counted like any other. The whole forked session is its context.
- **Network access** to the provider your Claude Code is configured for (Anthropic by default).

## How a question runs

Each question starts one process in the linked session's working directory:

```
claude -p --output-format stream-json --verbose --include-partial-messages \
  --strict-mcp-config --append-system-prompt <TalkMargin's prompt> \
  --resume <session> [--fork-session --name "🎙 Meeting · <session title>"] \
  --tools Read,Grep,Glob --allowedTools Read,Grep,Glob
```

The question goes in on standard input. The answer streams back into the chat column.

- **Fork, never the original.** The first question of a conversation resumes the session you linked with `--fork-session`. Claude Code then writes a new session (the fork) and leaves yours unchanged. Later questions resume the fork. The fork is named `🎙 Meeting · <title>` in `claude --resume`. **Cuộc trò chuyện mới** ("New conversation") makes the next question fork again.
- **Read-only tools.** Only Read, Grep and Glob are available and pre-approved. There is no shell, no editing and no web access. TalkMargin adds no path limits of its own; Claude Code's permission settings decide what those tools may read.
- **No MCP servers.** `--strict-mcp-config` is given without a config, so no MCP server is loaded.
- **Your Claude Code configuration still applies** for that directory, for example `CLAUDE.md` files, settings and hooks. Hooks are commands you configured, and they run as they would in a terminal.
- **No session linked:** questions run in a temporary folder (`$TMPDIR/MeetingPrompter`) with no tools at all (`--tools ""`). The first question starts a new session there.

## What is sent

To the provider, through Claude Code:

| Item | When |
|---|---|
| The forked session's history | Every question (it is the fork's context) |
| TalkMargin's system prompt: live-meeting assistant, brief, Vietnamese explanations, English lines to say | Every question |
| Your question, as typed or as reviewed after push-to-talk | Every question |
| An instruction to answer in Vietnamese and to write lines to say in English | Every question |
| The open document's text, up to **60,000 characters**, with a note when truncated, plus its full local path | The first question about a document, after a big edit, or when the session lost it (compaction) |
| A line diff of your edits, with the path | After smaller edits (diff no more than half the document's length) |
| A one-line notice ("switched back, unchanged") | When you return to a document Claude already has |
| File contents that Claude chooses to read with Read, Grep or Glob | When it uses those tools |

Nothing is sent until you press Enter. Push-to-talk text appears in the question box first, labelled `Others:` (the meeting audio) and `Tôi:` ("Me", your microphone), so you can edit or discard it. Speech recognition itself is on-device.

## What is stored on your Mac

| What | Where | Contents |
|---|---|---|
| Conversations | `~/Library/Application Support/MeetingPrompter/conversations.json` (dev build: `MeetingPrompter Dev/`) | At most 50 conversations, newest first. Each has the linked session (id, folder, title, date), the fork id, every question and answer (or error), and the path and SHA-256 digest of the document version each question was asked about. The notes text itself is not stored. |
| Linked session | The app's settings (`defaults read com.long.meetingprompter linkedSession`) | Session id, folder, title, date |
| Forks | `~/.claude/projects/…`, written by Claude Code | Full fork transcripts, kept and managed by Claude Code. TalkMargin never deletes them. |
| Terminal command | The clipboard, when you press **Terminal** | `cd '<folder>' && '<path to claude>' --resume <fork>` |

To list sessions, TalkMargin reads the start and the end of the transcript files in `~/.claude/projects/*/*.jsonl` on your Mac. Its own forks are left out of the session picker. The menu's **Session Claude** submenu lists all sessions.

## Limits

- The language of answers is fixed: Vietnamese explanations, English lines to say. It is set by the prompt in `Sources/MeetingPrompter/ClaudeChat.swift`.
- One question runs at a time; others wait in a queue. You cannot change the session while a question is being answered.
- Claude answers from the document that was on screen when you asked. Switching documents never changes the linked session or the conversation shown.
