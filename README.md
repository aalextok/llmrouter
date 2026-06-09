# llmrouter

A local-first LLM **model router** that grows into a Claude Code-style **agentic CLI** —
written in Go, powered by local models plus a free cloud fallback.

The through-line: learn Go on something real, and answer the hardware question —
can a 7–14B local model carry an agentic coding workload, or does it take a
bigger GPU? — with measured data instead of guesswork.

---

## Scope — keep it a pet project

Tiered on purpose. **Stop after any tier and you still have something finished.**

- **Tier 0 — the spine (a weekend).** Rules-based router + Ollama provider + one
  free cloud provider + SQLite logging + a single-prompt eval that prints a
  comparison table. Compiles, runs, and starts answering the hardware question.
  This is where the Go fundamentals get learned.
- **Tier 1 — the agent (the main build).** The Claude Code experience:
  an agent loop + read/edit/run tools + approval prompts, a plain REPL first,
  then a Bubble Tea TUI on top. The agentic eval (tool-call success rate, local
  vs cloud) is the sharp answer to the hardware question.
- **Tier 2 — only if still hooked.** Outcome-based cascade + an embedding
  classifier for learned routing, the usage dashboard, and a `doctor`/`setup`
  command plus a GPU-passthrough docker-compose.

Tier 0 alone justifies the project. Everything past it is for fun, not necessity.

---

## Architecture

A small `Provider` abstraction with the router and agent layered on top:

- **`Provider`** — takes a request, returns a completion *or tool calls*.
  Implementations: `OllamaProvider` (local) and one `OpenAICompatibleProvider`
  parameterized by base URL + key + model, reused for Groq / Gemini / Cerebras.
- **`Router`** — picks a provider. Tier 0: deterministic rules. Tier 2: an
  outcome-based cascade, then a learned embedding classifier.
- **`Store`** — SQLite log of every request (provider, model, latency, tokens,
  cost). Later doubles as training data for the classifier.
- **`Agent`** — the loop + tools (`read`, `edit`, `run`, `grep`) + approval gate.
  REPL-drivable, no UI dependency.
- **`TUI`** — Bubble Tea presentation layer over the agent.
- **`Eval`** — runs a task suite across models, emits a comparison report.

Keystone interface (now tool-calling capable — get this right and everything plugs in):

```go
package provider

import (
    "context"
    "encoding/json"
)

type ToolCall struct {
    Name string          `json:"name"`
    Args json.RawMessage `json:"arguments"`
}

type Response struct {
    Content      string
    ToolCalls    []ToolCall // present when the model wants to act
    InputTokens  int
    OutputTokens int
    Provider     string
    Model        string
    LatencyMS    int64
}

type Provider interface {
    Name() string
    Complete(ctx context.Context, req Request) (Response, error)
}
```

---

## Build order (mapped to the tiers)

**Phase 1 — Tier 0 spine.** Go modules + layout, the `Provider` interface, the
`OllamaProvider`, a rules router (privacy / token-budget / tag gates), SQLite
logging, a `/v1/complete` endpoint, and a single-prompt eval.
*Milestone:* `llmrouter eval --suite coding.yaml` prints the first
model-vs-model comparison table.

**Phase 2 — Tier 1 core (in a plain REPL).** Add tool-calling to the provider,
then build the agent loop and the core tools (`read`, `edit` with a diff,
`run`, `grep`) behind an approval gate. Drive it from a plain REPL — debugging
an agent loop is far easier when output is just scrolling text.
*Milestone:* `llmrouter chat` fixes a real failing test end to end, asking
permission before each edit/command.

**Phase 3 — Tier 1 UI.** Put a Bubble Tea TUI over the loop: sticky input box,
live todo list, rendered diffs, spinner, streaming via message events, slash
commands (`/model`, `/clear`). Keep a `--plain` REPL mode as the scripting/CI
fallback.
*Milestone:* the session looks and feels like Claude Code, routing badge under
each step.

**Phase 4 — Tier 1 payoff.** Build the agentic eval: run fixed tasks across
local 7B/14B and a cloud model, scoring success rate, tool-call validity,
step count, latency, and cost. Then write the verdict.
*Milestone:* a data-backed sentence — "local handled X% of agent steps unaided,
escalated Y%" — that sets the VRAM target. (Tier 2 cascade / classifier /
dashboard from here if it's still fun.)

---

## Repo layout

```
llmrouter/
  cmd/llmrouter/main.go        # flags → serve | chat | eval | doctor
  internal/
    config/                    # YAML config + validation
    provider/                  # Provider interface, tool-call types
      ollama.go
      openai_compatible.go     # Groq / Gemini / Cerebras via one struct
    router/
      rules.go                 # Tier 0: deterministic gates
      cascade.go               # Tier 2: outcome-based escalation
      classifier.go            # Tier 2: embedding classifier
    store/sqlite.go            # request log (+ later, training data)
    agent/
      loop.go                  # the plan→act→observe loop
      tools.go                 # read / edit / run / grep
      approval.go              # the y / a / n gate
    tui/                       # Tier 1 UI: Bubble Tea model/update/view
    eval/
      eval.go                  # suite loader + runner
      report.go                # markdown / CSV report
    server/                    # Tier 2: /v1 endpoint + static web chat
    doctor/                    # Tier 2: env checks + ollama pull
  suites/                      # coding.yaml … + agentic tasks (Phase 4)
  scripts/setup.sh             # env setup + doctor (precursor to `llmrouter doctor`)
  configs/config.example.yaml
  go.mod
```

`internal/` keeps the API surface honest; one binary under `cmd/`.

---

## Two design principles to hold onto

**Logic before presentation.** The `agent` package is the hard part and must be
fully usable from a plain REPL. The `tui` package is a thin renderer on top — the
loop emits events, the TUI draws them. This separation is why the `--plain` mode
comes free and why the loop stays testable.

**Rules first, smart later, cascade always.** Start with deterministic gates
(they're fast, free, deterministic — and determinism matters in the eval). Add
the outcome-based cascade for the agent (run local, escalate only when tests fail
or a tool call is malformed — routing on truth, not a guess). The embedding
classifier is a learned upgrade trained on the logged data, but keep the cascade
underneath as the correctness net: a misroute self-corrects and becomes a new
training example.

---

## Local environment (part of the project)

Setup is code, not a wiki page. One idempotent script checks the machine,
installs what's missing, and recommends models that actually fit the hardware;
in Tier 2 its checks graduate into `llmrouter doctor`.

```bash
./scripts/setup.sh          # detect hardware, install toolchain, recommend + pull models
./scripts/setup.sh --check  # doctor mode: report-only, exit 1 if anything is missing
```

It covers: git, GPU visibility, the Go toolchain, staticcheck, Ollama + its
service, and a hardware-based model recommendation (VRAM/RAM/disk-aware) —
e.g. an 8 GB GPU gets a 7B coder model at full speed plus a 14B as the
deliberate spill-to-RAM stress test, while bigger cards get bigger defaults.

Free cloud fallback (optional): Groq (OpenAI-compatible, fast 70B-class) or
Google AI Studio (Gemini).

---

## Working with a coding agent (how this gets built)

Paste this README and name the current milestone. Work test-first in small
increments — TDD loops are where agentic coding shines. Ask the agent to
explain the Go idioms it writes (turn it into a tutor). Keep `gofmt`, `go vet`,
and `staticcheck` running every loop. Commit at every milestone. Let it do the
big refactors, but read the diffs — the learning is in the review.
