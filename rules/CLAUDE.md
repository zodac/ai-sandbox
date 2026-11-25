# Organisation rules (ai-sandbox)

Shared by every project that uses ai-sandbox. Each project imports this file from its own `CLAUDE.md`
(`ai-sandbox/sandbox.sh init` adds the import), so a rule changed here reaches every project when it
moves to the new ai-sandbox tag. Put project-specific rules in the project's own `CLAUDE.md`, not here.

1. **Never use a feature branch.** Work on the branch that is currently checked out. Don't create,
   switch to or suggest a new branch. (`rules/hooks/guard-git-branch.sh` blocks the commands that create
   one.)
2. **Ask questions with the `AskUserQuestion` tool**, never as plain text at the end of a reply, so that
   the user gets a prompt.
3. **When you have finished any piece of work, write the full summary or report first, and only then
   notify the user with the `PushNotification` tool, as your last tool call.** The notification tells the
   user there is something to review, so the summary must be on screen before it is sent: never before the
   summary, and never mid-work. They may be away from the terminal (Remote Control), so make it one line
   under 200 characters, leading with the outcome or what needs their action. Write the summary as
   ordinary text, in full, every time - a short piece of work (a commit) still gets a short one, and a
   reply whose only text is "Done." has no summary. After the notification's result, end with one short
   closing line. It stops Claude Code re-prompting with "Your previous response had no visible output"; if
   you get that re-prompt anyway, answer it with one short line. Never repeat the summary or the
   notification: send one per piece of work. Skip it when the reply ends in `AskUserQuestion`, which
   already notifies. If `PushNotification` is a deferred tool, load it with `ToolSearch` before you write
   the summary, so that loading it doesn't come between the two. A "Not sent" result is normal when the
   user is at the terminal, so don't mention it.
