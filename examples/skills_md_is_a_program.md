# Skills.md is a Program Written in the Wrong Language

## The Dominant Paradigm

The standard way to give an AI agent a capability today is to write a markdown file.
You describe the workflow, list the rules, specify the tools, and enumerate the safety
constraints. The agent loads the document at runtime and — ideally — follows it.

This is the `skills.md` model. It is how the majority of deployed agents work today:
OpenAI Assistants, Claude projects, agent frameworks built on system prompts. The
prevailing assumption is that this is a **writing problem**. The better you write the
document, the better the agent behaves. The craft is prompt engineering.

This document argues that assumption is wrong — not at the margins, but
architecturally. A `skills.md` file is not documentation. It is a program written in
the wrong language.

---

## A Closer Look: What Is Actually in a skills.md

Take `healthcheck_skill.md`, a real skills file for a host security hardening agent.
It is 246 lines of English prose. Here is a representative sample:

```markdown
## Core rules

- Require explicit approval before any state-changing action.
- Do not modify remote access settings without confirming how the user connects.
- Prefer reversible, staged changes with a rollback plan.
- Never claim OpenClaw changes the host firewall, SSH, or OS updates; it does not.
- If role/identity is unknown, provide recommendations only.

## Workflow (follow in order)

### 1) Establish context (read-only)

Determine (in order):
1. OS and version (Linux/macOS/Windows), container vs host.
2. Privilege level (root/admin vs user).
3. Access path (local console, SSH, RDP, tailnet).
...

### 4) Determine risk tolerance (after system context)

1. Home/Workstation Balanced: firewall on, remote access restricted to LAN or tailnet.
2. VPS Hardened: deny-by-default inbound firewall, minimal open ports, key-only SSH.
3. Developer Convenience: more local services allowed, explicit exposure warnings.
```

This looks like documentation. It reads like a manual a human might follow. But look
more carefully at what it actually contains.

---

## The Four Layers Conflated in a skills.md

Every `skills.md` file is a mixture of at least four fundamentally different kinds of
specification, collapsed into a single flat document:

### Layer 1: Workflow Structure

```markdown
## Workflow (follow in order)
### 1) Establish context
### 2) Run OpenClaw security audits
### 3) Check version/update status
### 4) Determine risk tolerance
### 5) Produce a remediation plan
### 6) Offer execution options
### 7) Execute with confirmations
### 8) Verify and report
```

This is a **directed graph**. It has nodes (steps), edges (ordering), and conditional
branches (loop back if score below threshold). It belongs in topology, not prose.

### Layer 2: Output Schemas

```markdown
Determine (in order):
1. OS and version (Linux/macOS/Windows), container vs host.
2. Privilege level (root/admin vs user).
3. Access path (local console, SSH, RDP, tailnet).
4. Network exposure (public IP, reverse proxy, tunnel).
5. Disk encryption status (FileVault/LUKS/BitLocker).
6. OS automatic security updates status.
```

This is a **type definition**. It describes the fields, types, and constraints of a
structured object. It belongs in a schema, not prose.

### Layer 3: Semantic Guidance

```markdown
Most home/workstation users should get BALANCED.
Servers with public IPs should get HARDENED.
Machines with many dev services should get DEVELOPER.
```

This is **genuine reasoning** — judgment calls that require understanding context.
This is legitimately LLM territory. It belongs in semantic annotations, but it belongs
there because it is the one thing a language model is actually designed to do.

### Layer 4: Invariants and Safety Policy

```markdown
- Require explicit approval before any state-changing action.
- Do not modify remote access settings without confirming how the user connects.
- Never claim OpenClaw changes the host firewall, SSH, or OS updates; it does not.
- If role/identity is unknown, provide recommendations only.
```

These are **cross-cutting contracts** that apply regardless of which step the agent is
on. They are invariants. They belong in enforcement logic, not prose.

---

## The Diagnosis: A Natural Language Program

The reason all four layers are collapsed into one document is that when the LLM is your
only interpreter, you have no other place to put them. You cannot write a type system.
You cannot define a graph. You cannot enforce invariants. You can only write prose and
hope the runtime — the LLM — reconstructs the structure you intended.

**A `skills.md` file is what a program looks like when your only compilation target is
natural language comprehension.**

This reframes the problem entirely. The failures of skills-based agents — skipped
steps, schema drift, ignored safety rules, compliance degrading with context length —
are not failures of writing quality. They are the expected behavior of an interpreted
natural language program under pressure. You cannot fix them by writing better prose.
They are architectural.

---

## The Human Analogy: Proceduralization

In cognitive science, the process by which declarative knowledge ("here are the rules")
becomes procedural knowledge ("just do it") is called **proceduralization** — or in
Anderson's ACT-R framework, **compilation**.

A medical student reads textbooks. A skilled surgeon does not consult the textbook
mid-operation. The knowledge has been compiled from explicit rules into automated
procedures that no longer require conscious access to the source material. The textbook
is no longer in context. Only the acquired skill remains.

The `skills.md` approach keeps the textbook in context on every call. The entire
246-line document is present in the LLM's working memory for every API call, every
ReAct iteration, every tool invocation — because it has no other home.

This is not how skills work, in humans or in well-designed software systems.

---

## OSP as a Compiler for skills.md

Object-Spatial Programming (OSP) with `byLLM` provides the tooling to separate the
layers and route each to the right substrate. Here is the same healthcheck skill,
compiled:

### Layer 1 → Graph Topology

```jac
// The 8-step workflow becomes a graph of typed nodes
node ContextGathering {}
node SecurityAudit {}
node VersionCheck {}
node RiskAssessment {}
node PlanGeneration {}
node Execution {}
node Verification {}

edge RetryEdge {
    has reason: str = "Re-remediate: audit score below threshold";
}

// The ordering is structural, not instructional
root ++> ctx_node ++> audit_node ++> ver_node
     ++> risk_node ++> plan_node ++> exec_node ++> verify_node;

// The self-correction loop is a first-class edge
verify_node +>:RetryEdge():+> plan_node;
```

The agent cannot skip `SecurityAudit` and jump to `PlanGeneration`. The graph does not
permit it. Compliance is architectural.

### Layer 2 → Type Definitions

```jac
// "Determine OS, privilege, access path, network exposure..."
// becomes a typed object with enforced fields

obj SystemContext {
    has os: OS;
    has os_version: str;
    has privilege: Privilege;
    has access_path: str;
    has network_exposure: str;
    has disk_encrypted: bool;
    has auto_updates: bool;
}

obj RemediationStep {
    has description: str;
    has command: str;
    has impact: str;
    has rollback: str;      // non-optional: LLM must populate this
    has is_critical: bool;
}
```

If `rollback` is empty, structured output validation fails before execution is reached.
The type system enforces what the prose merely requested.

### Layer 3 → Semantic Annotations

```jac
// The reasoning guidance becomes a compressed sem string
// attached to the function that actually needs it

def recommend_risk_profile(context: SystemContext) -> RiskProfile by llm();
sem recommend_risk_profile = """
    Home/workstation users should get BALANCED.
    Servers with public IPs should get HARDENED.
    Developer machines with many local services should get DEVELOPER.
""";
```

The semantic guidance still exists — but it is scoped to the single function that
requires it, not broadcast to every API call for the entire workflow lifetime.

### Layer 4 → Walker and Node Abilities (the key insight)

This is where the argument sharpens. The invariants — the safety rules that
`skills.md` carries as hope — can be programmed as enforcement:

**"Require explicit approval before any state-changing action"**

```jac
node AwaitApproval {
    has action_description: str;
    has command: str;
}

walker HealthChecker {
    has approved: bool = False;

    can gate with AwaitApproval entry {
        print(f"Approve: {here.command}? (y/n)");
        self.approved = input() == "y";
        if not self.approved {
            disengage;  // walker stops, structurally cannot reach Execution
        }
        visit [-->];
    }
}

// The graph enforces the gate — Execution is unreachable without it
plan_node ++> approval_node ++> exec_node;
```

**"If role/identity is unknown, provide recommendations only"**

```jac
can assess with RiskAssessment entry {
    self.target_risk = recommend_risk_profile(self.context);

    // Invariant: unknown privilege → plan only, enforced in code
    if self.context.privilege == Privilege.USER {
        self.execution_choice = ExecutionChoice.PLAN_ONLY;
    }
    visit [-->];
}
```

**"Do not modify remote access settings without confirming how the user connects"**

```jac
can plan_step with PlanGeneration entry {
    self.plan = generate_remediation_plan(
        self.audit, self.context, self.target_risk.name
    );

    // Validate generated plan against system context
    for step in self.plan.steps {
        if step.touches_remote_access and self.context.access_path == "SSH" {
            step.is_critical = True;  // forces approval gate
        }
    }
    visit [-->];
}
```

Each invariant that `skills.md` expressed as a sentence the LLM might or might not
follow is now a deterministic check that runs regardless of what the LLM produced.

---

## What Each Layer Maps To

| Layer | skills.md puts it in | OSP substrate | Enforced by |
|---|---|---|---|
| Workflow structure | Prose ("Follow in order") | Graph topology | Graph traversal |
| Output schemas | Prose ("Determine: OS, ports...") | `obj` type definitions | Type system |
| Semantic guidance | Prose | `sem` annotations | LLM (appropriately) |
| Invariants / policy | Prose | Walker/node ability logic | Jac runtime |

The LLM's job is reduced to exactly what it is good at: classification, extraction, and
generation at well-defined boundaries. Everything else is code.

---

## Token Efficiency is a Symptom, Not the Disease

The experiment in `examples/experiment/` measures the token cost of the two approaches:

| Metric | Baseline (skills.md) | OSP |
|---|---|---|
| API calls | 7 | 5 |
| Total tokens | ~7,839 | ~3,521 |
| Token growth per call | 620 → 1,472 (accumulating) | 627 → 472 (flat) |
| Cost per run | $0.00124 | $0.000989 |

The 55% token reduction is real and significant. But it is a *symptom* of the
architectural difference, not the core argument. The baseline grows because the skill
text stays in context for every API call in the ReAct loop. OSP is flat because each
node only sees what it needs.

The more important difference is not measured in tokens: the OSP version does not
*rely* on the LLM having read and retained the 246-line document. The workflow order is
enforced by the graph. The output schemas are enforced by the type system. The
invariants are enforced by the walker logic. None of these are contingent on the LLM
paying attention.

---

## What Remains Genuinely Hard

One category of invariant does not yet have a clean home in OSP:

```markdown
Never claim OpenClaw changes the host firewall, SSH, or OS updates; it does not.
```

This is a **semantic correctness assertion** about the meaning of LLM-generated output,
not its structure. The type system can enforce that `PostureReport` has the right
fields. It cannot enforce that the content of those fields doesn't contain a false
claim.

The options are:
1. A post-generation validation `by llm()` call that checks the output against the
   constraint — which works but adds a call
2. A keyword/pattern scan over generated text — fragile
3. Fine-tuning the model against the constraint — which is actual weight-level
   compilation, the closest analog to human skill acquisition

This is the real residual category where `sem` is still doing genuine interpretive
work, and where the natural language layer remains load-bearing.

---

## The Disruptive Claim

The `skills.md` paradigm frames agent development as a **writing problem**. The better
you write the document, the better the agent. Prompt engineering is the craft. When
agents fail, you improve the prose.

This argument says the problem is **architectural, not authorial**. Most of what a
`skills.md` file contains is not prose — it is workflow, types, and invariants that
have been forced into prose because the tooling to express them properly did not exist.

The implications:

**Authoring skills changes discipline.** Writing a skill is not a writing task. It is a
multi-layer engineering task: graph design, type design, semantic annotation, and policy
encoding. A `skills.md` file is an uncompiled program. OSP is the compiler.

**The "improve the prompt" loop hits a ceiling.** Some agent failures are not fixable
with better writing. They are structural. Recognizing which failures belong to which
category is the new diagnostic skill.

**The LLM's role is redefined.** In the skills.md paradigm, the LLM is a general
interpreter of everything — workflow, schema, policy, reasoning. In OSP, it is a
specialist called at well-defined semantic boundaries. The reduction in scope makes it
both more reliable and more auditable.

**Compliance becomes verifiable.** With skills.md, you cannot prove the agent followed
the workflow. You can only observe outputs and infer. With OSP, the graph traversal is
inspectable. The type contracts are checkable. The invariant gates either fired or they
didn't.

---

## The Scope Limit

The disruptive argument has a boundary. For genuinely open-ended tasks — research,
exploratory coding, novel problem solving — where the workflow cannot be pre-specified,
the skills.md model retains its role. You cannot compile a graph for a task whose shape
is unknown in advance.

The `sem` annotations in OSP code are mini skill-prose. They have not been eliminated;
they have been compressed and scoped to the nodes that actually need them.

The productive way to frame the scope: **OSP does not replace skills.md. It compiles
it.** For the large class of tasks that appear to require open-ended interpretation but
actually have a definite workflow shape, the compilation is possible and beneficial. The
disruptive claim is that this class is much larger than the field currently assumes.

The healthcheck is the clearest example. It looks like a complex autonomous task. It
has a definite shape: gather, audit, assess, plan, execute, verify. That shape can be
compiled. What remains in prose — "home users get BALANCED, VPS gets HARDENED" — is
the genuinely semantic residue. Everything else was never prose to begin with.

---

## Summary

| Concept | skills.md view | This argument |
|---|---|---|
| What is skills.md? | A document / manual | A natural language program |
| What is the authoring problem? | Writing quality | Architectural separation |
| What is the LLM's role? | General interpreter | Semantic specialist |
| What enforces workflow order? | LLM following instructions | Graph topology |
| What enforces output schemas? | LLM following instructions | Type system |
| What enforces safety invariants? | LLM following instructions | Walker/node ability logic |
| What enforces semantic correctness? | LLM following instructions | LLM (this part is correct) |
| When does compliance fail? | When the LLM ignores prose | When the code has bugs |

The last row is the sharpest version of the argument. Compliance failures in OSP are
bugs — they are findable, fixable, and testable. Compliance failures in skills.md are
*interpretation failures* — they are probabilistic, context-dependent, and not
systematically debuggable.

**Skills.md is a program. OSP is what happens when you compile it.**
