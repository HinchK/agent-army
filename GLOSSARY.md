# Agent-Army

The organization that runs one mission on one git repository: one planner, disposable workers, a file ledger, a deterministic gate, and an operator who alone crosses the boundaries the army must not cross.

## Language

### People and seats

**Operator**:
The human responsible for a mission. The army runs for the operator and stops where only the operator may act.
_Avoid_: user, admin, reviewer

**Commander**:
The single long-horizon planner for a mission. The commander splits the work. The commander is not the ledger.
_Avoid_: truth-keeping lead, special forces, source of truth

**Worker**:
A disposable contributor given one disjoint slice of a mission. Its output stays untrusted until the gate passes it.
_Avoid_: troop, subagent, swarm member

**Verifier**:
A reviewer that starts without the author's context. A verifier rejection stands. A verifier approval does not, by itself, pass the gate.
_Avoid_: gate, supervisor

### The work

**Mission**:
One bounded objective on one git repository, finished when its exit is met or the operator must step in.
_Avoid_: task, ticket, campaign

**Canary**:
A mission whose only purpose is to prove the army can Promote. The change itself is disposable.
_Avoid_: smoke test, demo

**Wave**:
A set of disjoint slices worked at the same time, then folded into the ledger before any further plan.
_Avoid_: sprint, batch

**Security boundary**:
A kind of action reserved for the operator. Reaching one stops the mission until the operator acts.
_Avoid_: permission, danger zone

### Truth and judgment

**Ledger**:
The durable, human-readable record of what a mission has done. Later work trusts the ledger, not the commander's conversation.
_Avoid_: memory, context, Memorilla

**Gate**:
The deterministic judgment that a proposed change meets the repository's own checks. Nothing else can make a change count as passed.
_Avoid_: self-certified green, verifier

**Promote**:
Accepting gated work onto the repository's local baseline. It follows a passed gate, without an operator decision and without leaving the machine.
_Avoid_: publish, ship, merge to origin

**Publish**:
Moving that local baseline onto the remote main branch. Only the operator does this. The army stops beforehand.
_Avoid_: promote, deploy
