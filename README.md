# Daybook — local daily & weekly planner

A private, native Mac to-do app (SwiftUI, one process, no server, no web view). No accounts,
no cloud, no internet needed. All data lives in
**`~/Library/Application Support/Daybook/tasks.json`**.

## Open it

Double-click **Daybook.app** (drag it to the Dock). One window, shown in the Dock and Cmd-Tab,
Dock badge = open tasks due today or overdue. Closing the window keeps Daybook in the Dock (the
AI chats check keeps running); **⌘Q** quits. Appearance and settings: **⌘,**.

Rebuild after changing code: `./build.sh` (needs only the Xcode Command Line Tools).

## Files

```
Sources/
  Models.swift      data model (mirrors tasks.json, keeps unknown keys), date helpers
  Store.swift       load / atomic save / daily backups / outside-edit detection / first-run import
  AppModel.swift    engine: task operations, undo, drag & drop, view content, AI chats sync
  QuickAdd.swift    natural-language quick add parser
  AIChats.swift     AI coding chats → Board (reads local chat transcripts, read-only)
  MainView.swift    window, sidebar, quick add bar, toasts
  Views.swift       Today / Inbox / Upcoming / Lists / Completed / Search, This Week, Board
  DetailView.swift  task inspector
  Sheets.swift      AI chats, keyboard shortcuts, ⌘K palette
  App.swift         menus, single-key shortcuts, settings
```

## Views

| View | What it's for |
| --- | --- |
| **Today** (`1`) | Today's plan, overdue items (one-click "move all to today"), progress, items to pull in from the Inbox |
| **This week** (`2`) | 7-day board: drag tasks between days, weekly focus goals, week notes, Inbox column |
| **Inbox** (`3`) | Tasks with no date: capture now, plan later |
| **Upcoming** (`4`) | Everything scheduled after today, by day |
| **Completed** (`5`) | Logbook of finished tasks |
| **Board** (`6`) | Status columns: To do → In progress → In review → Blocked → Done. Drag to change status |
| **Lists** | e.g. Work, Personal. Create with **+**; right-click to rename, recolour or delete; drag to reorder |

Click a task to open it in the inspector on the right (status, date, time, list, priority,
estimate, repeat, tags, checklist, notes, its AI chat). Drag tasks between days, columns,
sidebar items and lists; right-click for every action. **⌘K** opens a palette to jump to any task
or run a command.

## AI chats → Board (optional, off by default)

Click the ✦ icon in the toolbar or at the bottom of the sidebar and switch on **Add work chats to the Board**.
From then on, new AI coding-assistant chats about a **PR, a task or an issue** become an
item dated the day the chat started, in the Work list:

- **PR reviews** start in **In progress**.
- **Tasks, bugs and issues** start in **To do** and move to **In progress** once that chat
  makes a plan (plan mode, a saved plan, or you ask it to "make a plan") or starts changing
  code (file edits in the repo, a commit, a new branch/worktree, `gh pr create`). Reading and
  investigating doesn't count. This happens once; if you move the item yourself, it stays put. A chat counts as
work when its title or first message has a ticket ID (`ABC-123`), a GitHub PR or Linear
issue link, mentions a PR, or says a task/bug was assigned. Everything else (stand-ups,
questions, personal chats, "btw:" side chats) is skipped. Several chats about the same
PR or ticket give one item. Daybook checks
once a minute while it's running, and only reads the chat transcripts saved on this Mac.

- Each item's title starts with its type, then the Linear ticket and/or PR number when the
  chat has them: `[Bug] ABC-77 · Form loses unsaved changes`, `[PR] ABC-123 · #4521 · Invoice export…`.
  Types are **[PR]**, **[Task]**, **[Bug]** or **[Issue]**.
  The type comes from how you phrase the chat ("a new bug assigned" → Bug, "a new task got
  assigned" → Task); otherwise bug-like words (breaks, error, data lost, fix…) mean Bug, else Task.
  PR and TRD review chats are always [PR]. Rename an item freely; your title is kept.
- Each chat is added once; delete the item and it stays gone.
- The item's title follows the chat's title once the assistant names it (unless you renamed the item).
- **PR review** items get a 30-minute estimate by default (change it freely; yours is kept).
- Open the item to see its project and branch. **Open chat** jumps to that chat in the
  desktop app (archived chats must be unarchived first). **CLI** copies a Terminal command that
  resumes it. Chats started in the Terminal only have the CLI option.

## Quick add

Type naturally in the big input (`N` to focus it):

```
Review PR tomorrow #work !high 30m
Pay electricity bill fri 10am #personal
Standup notes every weekday 9:30
Plan Q1 roadmap next week 2h
```

- Dates: `today`, `tomorrow`, `mon`…`sun`, `next fri`, `next week`, `weekend`, `in 3 days`, `nov 20`, `20 dec`, `2026-12-01`
- Time: `3pm`, `9:30am`, `15:30`
- List: `#work` (matches a list name); any other `#word` becomes a tag
- Priority: `!high` / `!med` / `!low` (or `!1` `!2` `!3`)
- Estimate: `15m`, `1h`, `1.5h`, `1h30m`
- Repeat: `every day`, `every weekday`, `every week`, `every month`, `every mon`

## Keyboard

`N` new · `/` or `⌘F` search · `⌘K` palette · `1–6` views · `J/K` or arrows to move · `X`/`Space` complete ·
`↩` open · `E` edit title · `T` today · `M` tomorrow · `W` next week · `I` no date · `S` status · `P` priority ·
`D`/`⌫` delete · `⌘D` duplicate · `⌘O` open AI chat · `⌘Z` undo · `[` `]` previous/next week ·
`?` all shortcuts · `Esc` close.

## Backups

On the first save of each day, the previous file is copied to `backups/tasks-YYYY-MM-DD.json`
next to `tasks.json` (the last 21 days are kept). To restore one, quit Daybook and copy it over
`tasks.json`.

## Data format (`~/Library/Application Support/Daybook/tasks.json`)

You (or an AI assistant) can edit this file directly. The open app checks the file every 2 seconds
and reloads when it changes (if you both changed it, the newest `updatedAt` per task wins).

```jsonc
{
  "version": 1,
  "lists": [ { "id": "work", "name": "Work", "color": "#5b6cff" } ],
  "tasks": [
    {
      "id": "k3j9x2a1b2c",         // any unique string
      "title": "Review PR",
      "notes": "",                  // free text, URLs become links
      "date": "2026-11-12",         // "YYYY-MM-DD" scheduled day, or "" = Inbox
      "time": "15:30",              // "HH:MM" 24h, or ""
      "listId": "work",             // a lists[].id, or ""
      "priority": 3,                // 0 none, 1 low, 2 medium, 3 high
      "estimate": 30,               // minutes, 0 = none
      "tags": ["urgent"],
      "subtasks": [ { "id": "s1", "text": "Read diff", "done": false } ],
      "repeat": "",                 // "", "daily", "weekdays", "weekly", "monthly"
      "done": false,
      "doneAt": null,               // local "YYYY-MM-DDTHH:MM:SS" when completed
      "createdAt": "2026-11-11T09:00:00",
      "updatedAt": "2026-11-11T09:00:00",
      "order": 1,                   // sort order within a day/list (lower = higher up)
      "status": "in_progress",      // "todo" | "in_progress" | "review" | "blocked" | "done" (done ⇔ status "done")
      "links": [                    // only for items created from an AI chat
        { "id": "l1", "type": "ai-chat", "ref": "<chat id>", "title": "chat title",
          "meta": { "project": "my-app", "branch": "main", "resume": "<terminal command that resumes the chat>" } }
      ]
    }
  ],
  "weeks": {
    "2026-11-09": {                 // key = Monday of that week
      "goals": [ { "id": "g1", "text": "Ship onboarding v2", "done": false } ],
      "notes": "Free text"
    }
  },
  "settings": { "theme": "system" }, // "system" | "light" | "dark"
  "integrations": { "aiChats": { "enabled": false, "since": "" } }  // AI chats → Board
}
```

Other files next to it: `ai-chats-index.json` (what has been read from chat files) and
`ai-chats-state.json` (chats already added, last check).

Missing fields are filled with defaults when the app loads, so a new task only needs
`id` and `title`. Repeating tasks: when one is completed, a fresh copy is created on the
next date and the completed one stops repeating.
