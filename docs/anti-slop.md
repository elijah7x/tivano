# Anti-slop guidance

Tivano ships a short, built-in block of guidance that asks the model for the shortest complete answer: leading with the result, skipping filler and hype, keeping comments only where they explain a non-obvious reason, and making focused edits instead of unrelated cleanup. The same block asks for product-fitting UI structure and for evidence to be reused rather than re-read.

## Built in to Tivano's own API harness

The guidance is always included in the system prompt of Tivano's own API harness (`OpenAICompatibleSession`, used by the DeepSeek, Meta and Z.ai providers), where Tivano itself manages the model session. There is no user-facing setting or toggle to turn it off.

Nothing is promised about token savings. Shorter replies and fewer redundant reads usually use fewer tokens, but the model, the task and the provider's own behavior all vary, so no fixed saving is guaranteed and no such claim is made in the UI.

## External agents and Hydra heads

Tivano does not send this guidance to external agent CLIs (such as Claude Code, Codex, Copilot, OMP and ACP-style agents). Mature external agents ship their own harness and already manage their own output style.

Delegated work — Hydra heads — follows the same split: heads running on Tivano's API providers receive the guidance in their system prompt just like a main session, while heads backed by external agents rely on their own harness.

## A compact authored adaptation, not upstream tooling

The guidance in `Tivano/Core/Models/AntiSlopPolicy.swift` is a compact adaptation authored for Tivano. It is not an installation of the upstream anti-slop project, and it does not run any of its tooling.

Upstream inspiration: [miqdadbadjuber/anti-slop](https://github.com/miqdadbadjuber/anti-slop) at revision [`743735248fbaefd76bb56619615687dfa8b3bc1e`](https://github.com/miqdadbadjuber/anti-slop/tree/743735248fbaefd76bb56619615687dfa8b3bc1e), MIT licensed, copyright 2026 Miqdad Badjuber. The upstream [LICENSE](https://github.com/miqdadbadjuber/anti-slop/blob/743735248fbaefd76bb56619615687dfa8b3bc1e/LICENSE) applies to that work.

What is intentionally left out of Tivano:

- The upstream wizard and its interactive setup.
- Mandatory audit reports.
- External executables or scripts the upstream project may invoke.

Tivano carries only the guidance text, as a value it can hand to a provider. It installs nothing, runs no audit, and requires no external binary.
