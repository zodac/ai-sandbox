# Organisation rules (ai-sandbox)

Shared by every project that uses ai-sandbox. Each project imports this file from its own `CLAUDE.md`
(`ai-sandbox/sandbox.sh init` adds the import), so a rule changed here reaches every project when it
moves to the new ai-sandbox tag. Put project-specific rules in the project's own `CLAUDE.md`, not here.

1. **Never use a feature branch.** Work on the branch that is currently checked out. Don't create,
   switch to or suggest a new branch. (`rules/hooks/guard-git-branch.sh` blocks the commands that create
   one.)
2. **Ask questions with the `AskUserQuestion` tool**, never as plain text at the end of a reply, so that
   the user gets a prompt.
3. **When you have finished any piece of work, notify the user with the `PushNotification` tool, as
   your last tool call, and then write the full summary or report as your final message.** The summary
   goes after the notification, not before it: a reply that ends on a tool call has no text after that
   tool's result, so Claude Code re-prompts with "Your previous response had no visible output", and
   answering that repeats the summary. Send one notification per piece of work, and write the summary
   once. If you get that re-prompt anyway, reply with one short line and don't repeat the summary or the
   notification. If `PushNotification` is a deferred tool, load it with `ToolSearch` before you start the
   work's last step. A "Not sent" result is normal when the user is at the terminal, so don't mention it.
