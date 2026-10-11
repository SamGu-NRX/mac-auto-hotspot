# AGENTS.md

<!-- agent-skills:start -->
## Agent skills

Before starting work, read the skills below that apply to the task; each SKILL.md says when to use it. They are Sam's working playbooks and Lauren Tan's pstack (`pstack-*`), chosen for this repo. Obvious Autobuild loads them from `.obvious/skills/` on the default branch.

- [`blast-radius`](.obvious/skills/blast-radius/SKILL.md): Assess what a change could break beyond its diff
- [`pstack-architect`](.obvious/skills/pstack-architect/SKILL.md): Sketch types, signatures, and module structure before code, then stay in the loop while implementation fills in
- [`pstack-create-verification-skill`](.obvious/skills/pstack-create-verification-skill/SKILL.md): Generate a project-local verification skill that drives your app the way a user does — any language, framework, or platform
- [`pstack-principle-boundary-discipline`](.obvious/skills/pstack-principle-boundary-discipline/SKILL.md): Apply when wiring validation, error handling, or framework adapters
- [`pstack-principle-make-operations-idempotent`](.obvious/skills/pstack-principle-make-operations-idempotent/SKILL.md): Apply when designing commands, lifecycle steps, or processing loops that run amid crashes, restarts, and retries
- [`pstack-principle-model-the-domain`](.obvious/skills/pstack-principle-model-the-domain/SKILL.md): Apply when writing stateful logic, or when code branches a lot or repeats a shape assumption across files
- [`pstack-principle-prove-it-works`](.obvious/skills/pstack-principle-prove-it-works/SKILL.md): Apply after completing a task, before declaring done
- [`pstack-principle-separate-before-serializing-shared-state`](.obvious/skills/pstack-principle-separate-before-serializing-shared-state/SKILL.md): Apply when concurrent actors might write to the same file, branch, key, or state object
- [`pstack-principle-test-behavior-not-implementation`](.obvious/skills/pstack-principle-test-behavior-not-implementation/SKILL.md): Apply when you write, change, or keep a test
- [`pstack-principle-type-system-discipline`](.obvious/skills/pstack-principle-type-system-discipline/SKILL.md): Apply when designing types, reviewing a function signature, or writing code in any statically-typed language
- [`pstack-technical-writing`](.obvious/skills/pstack-technical-writing/SKILL.md): Layered technical-writing standard: Diátaxis structure, Google developer style sentences, STE instruction rules, Global English syntax
- [`pstack-arena`](.obvious/skills/pstack-arena/SKILL.md): Spawn N parallel candidates at the same task, pick a base, graft the strongest parts of the losers into it *(needed by `pstack/architect`)*
<!-- agent-skills:end -->
