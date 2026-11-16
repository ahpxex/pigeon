import Foundation

/// File contents ActivityHooks installs: the shared reporter script and
/// the pi extension. Kept apart from the install/merge logic so each
/// file stays readable.
extension ActivityHooks {
    /// Bumped whenever the script or extension changes; installed copies
    /// without the current marker are rewritten on launch.
    static let reporterVersionMarker = "pigeon-activity-v4"

    /// `pigeon-activity <event> <source> [hook-input.json]`
    ///
    /// The host's hook input (JSON) comes from the file argument (prompt
    /// events: the hook command saves stdin first) or straight from stdin.
    /// It is forwarded verbatim with Pigeon's fields spliced in at the end
    /// — no JSON parsing in shell, so no payload can make a parse step
    /// fail and drop the event (an idle lost that way leaves the tab
    /// spinning). The spliced keys
    /// come last so they win over a host field of the same name (Codex's
    /// SessionStart carries its own `source`); `pigeon_event`/
    /// `pigeon_source` are unambiguous copies for current Pigeon, while
    /// `event`/`source` keep older Pigeon builds (which share this file)
    /// working.
    ///
    /// `permission` holds until Pigeon decides and prints the reply on
    /// stdout, which Claude Code and Codex read as the PermissionRequest
    /// decision. Printing nothing leaves the host's own prompt in charge.
    static let reporterScript = """
        #!/bin/sh
        # pigeon-activity-v4
        # (supersedes pigeon-activity-v3: older Pigeon builds look for that
        # marker and must keep accepting this script instead of rewriting it)
        # pigeon-activity — installed by Pigeon (Settings → Agent).
        # Reports coding-agent state to the Pigeon tab that launched the
        # agent. Called as:
        #   pigeon-activity <event> <source> [hook-input.json]
        # The hook input JSON (file argument, else stdin) is forwarded with
        # the event and source added. For `permission` Pigeon's decision is
        # printed on stdout; no output keeps the agent's own prompt.
        # Outside Pigeon this silently no-ops.
        [ -n "$PIGEON_AGENT_PORT" ] && [ -n "$PIGEON_AGENT_TOKEN" ] && [ -n "$PIGEON_SURFACE_ID" ] || exit 0
        case "$1" in ping|busy|idle|attention|permission) ;; *) exit 0 ;; esac
        case "$2" in pi|claude-code|codex) ;; *) exit 0 ;; esac

        if [ -n "${3:-}" ] && [ -f "$3" ]; then
          input=$(/bin/cat "$3" 2>/dev/null)
        elif [ ! -t 0 ]; then
          input=$(/bin/cat 2>/dev/null)
        else
          input=""
        fi

        fields="\\"event\\":\\"$1\\",\\"source\\":\\"$2\\",\\"pigeon_event\\":\\"$1\\",\\"pigeon_source\\":\\"$2\\""
        inner=""
        case "$input" in
          "{"*"}") inner=${input#\\{}; inner=${inner%\\}} ;;
        esac
        case "$inner" in
          *[![:space:]]*) body="{$inner,$fields}" ;;
          *) body="{$fields}" ;;
        esac

        if [ "$1" = permission ]; then
          # Held until someone decides in Pigeon (or the hook is cancelled
          # because the agent's own prompt was answered first).
          printf '%s' "$body" | /usr/bin/curl --noproxy '*' --silent --fail \\
            --connect-timeout 0.25 --max-time 3590 \\
            -X POST "http://127.0.0.1:$PIGEON_AGENT_PORT/permission" \\
            -H "Authorization: Bearer $PIGEON_AGENT_TOKEN" \\
            -H "X-Pigeon-Surface: $PIGEON_SURFACE_ID" \\
            -H "Content-Type: application/json" -H "Expect:" \\
            --data-binary @- 2>/dev/null
          exit 0
        fi

        # Wait for Pigeon to accept the event before the hook exits, so the
        # host can't tear the request down before it is delivered.
        printf '%s' "$body" | /usr/bin/curl --noproxy '*' --silent --fail --output /dev/null \\
          --connect-timeout 0.25 --max-time 2 \\
          -X POST "http://127.0.0.1:$PIGEON_AGENT_PORT/activity" \\
          -H "Authorization: Bearer $PIGEON_AGENT_TOKEN" \\
          -H "X-Pigeon-Surface: $PIGEON_SURFACE_ID" \\
          -H "Content-Type: application/json" -H "Expect:" \\
          --data-binary @- >/dev/null 2>&1
        # Activity reporting must never break the coding agent itself.
        exit 0
        """

    static let piExtensionSource = #"""
        import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

        // pigeon-activity-v4
        // (supersedes pigeon-activity-v3: older Pigeon builds look for that
        // marker and must keep accepting this file instead of rewriting it)
        // pigeon-activity — installed by Pigeon (Settings → Agent).
        // Reports pi's run state to the Pigeon tab that launched it: the
        // sidebar spinner, the message outline, the final reply of each
        // run, and when pi is waiting on the user. No-op outside Pigeon
        // (no PIGEON_* environment).
        export default function (pi: ExtensionAPI) {
          const port = process.env.PIGEON_AGENT_PORT;
          const token = process.env.PIGEON_AGENT_TOKEN;
          const surface = process.env.PIGEON_SURFACE_ID;
          if (!port || !token || !surface) return;

          const report = async (event: string, fields: Record<string, unknown> = {}) => {
            try {
              const response = await fetch(`http://127.0.0.1:${port}/activity`, {
                method: "POST",
                headers: {
                  Authorization: `Bearer ${token}`,
                  "X-Pigeon-Surface": surface,
                  "Content-Type": "application/json",
                },
                body: JSON.stringify({ ...fields, event, source: "pi" }),
                signal: AbortSignal.timeout(2000),
              });
              if (!response.ok) throw new Error(`Pigeon returned ${response.status}`);
            } catch {
              // Pigeon may have exited; reporting must not break pi.
            }
          };

          // Text of the latest assistant message in the current run.
          let lastReply: string | undefined;
          const textOf = (message: any): string | undefined => {
            const content = message?.content;
            if (typeof content === "string") return content;
            if (!Array.isArray(content)) return undefined;
            const text = content
              .filter((part: any) => part?.type === "text" && typeof part.text === "string")
              .map((part: any) => part.text)
              .join("");
            return text.trim() ? text : undefined;
          };

          // Returning the promise makes pi await delivery before it moves
          // to the next lifecycle event.
          pi.on("session_start", () => report("ping"));
          pi.on("before_agent_start", (event) => {
            lastReply = undefined;
            return report("busy", { prompt: event.prompt });
          });
          pi.on("message_end", (event) => {
            if (event.message?.role !== "assistant") return;
            const text = textOf(event.message);
            if (text) lastReply = text;
          });
          // agent_settled (not agent_end): pi may auto-retry or compact
          // and continue — settled is the "really done" signal.
          pi.on("agent_settled", () => report("idle", { reply: lastReply }));
          // A blocking extension prompt (select/confirm/input) is waiting
          // on the user; its end means work continues.
          pi.on("ui_prompt_start", () => report("attention", { message: "pi is waiting for your answer" }));
          pi.on("ui_prompt_end", () => report("attention", { cleared: true }));
          pi.on("session_shutdown", () => report("idle", { ended: true }));
        }
        """#
}
