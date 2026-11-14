# Organisation rules (ai-sandbox)

Shared by every project that uses ai-sandbox. Each project imports this file from its own `CLAUDE.md`
(`ai-sandbox/sandbox.sh init` adds the import), so a rule changed here reaches every project when it
moves to the new ai-sandbox tag. Put project-specific rules in the project's own `CLAUDE.md`, not here.

1. **Never use a feature branch.** Work on the branch that is currently checked out. Don't create,
   switch to or suggest a new branch.
2. **Ask questions with the `AskUserQuestion` tool**, never as plain text at the end of a reply, so that
   the user gets a prompt.
3. **When you have finished any piece of work, notify the user with the `PushNotification` tool, as
   your very last action.** Write the full summary or report first. Then send the notification, and add
   nothing after it: no more text, and no more tool calls. If it is a deferred tool, load it with
   `ToolSearch` before you write the summary, so that loading it doesn't come between the summary and the
   notification.
