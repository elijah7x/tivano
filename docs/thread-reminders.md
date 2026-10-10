# Thread reminders

The sidebar separates live work, unresolved requests, and unread terminal results.
`lastStatus` retains history. Reading never approves a request, answers a question,
or settles a task.

| Indicator | Condition | Opening the rendered conversation |
| --- | --- | --- |
| Spinner | Turn, helper, background task, merge, or limit continuation still pending | Remains |
| Yellow | Unresolved approval | Remains until resolved |
| Purple | Unresolved question | Remains until resolved |
| Green | Unread successful terminal result | Clears |
| Red | Unread failed terminal result | Clears |
| Grey outline | Unread unexpected interruption | Clears |
| None | Read result, unused thread, or deliberate stop | None |

Priority: approval, question, live work, unread terminal result.

Read receipts come from mounted timeline views in an active, visible window,
after history loads. Hidden child conversations are not read merely by selecting
the parent. Receipts compare `unreadRevision`; an older rendered snapshot cannot
clear a newer result. `lastAttentionTurnID` suppresses repeated completion events.
Pending work is persisted and recovered as an interruption after restart.

## Verification (2026-10-09)

41 temporary behavior checks exercised the actual status resolver and extracted
AppModel methods: terminal read/unread, request precedence, live-work precedence,
new completion after reading, stale receipts, redelivery, deliberate/unexpected
stop, queued successor, limit wait, background task, merge, and helper completion.
These use runtime stubs and do not establish real-window behavior.

Debug xcodebuild passed. No application was installed or launched.

The following require real-window acceptance when the owner runs the build:

- Finish while the current conversation is visible; no residual terminal dot.
- Finish while viewing another conversation; opening clears its dot.
- Finish while hidden/minimized/backgrounded; returning to the actual timeline clears it.
- Open an already-selected conversation after background completion.
- Leave a helper collapsed or its panel closed; opening its parent must not read it.
- Open the helper itself; its reminder clears.
- Resolve one of multiple approvals/questions; remaining requests retain their indicator.
- Restart with read and unread results, and with pending work; read remains read,
  unread remains unread, pending work is marked interrupted.
- Revert a result or manually settle it; stale reminders and Dock count clear.
- Final background task/merge completes or fails; only the final outcome reminds.

The temporary status-control render is a component check, not a full sidebar screenshot.
