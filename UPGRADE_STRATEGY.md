# Upgrade Strategy

usufruct does not upgrade. It versions.

This document explains why that is not a limitation — it is the correct decision for a functional-style protocol on Sui, and it follows directly from three independent observations that converge on the same conclusion.

---

## The Constraint

Sui's upgrade system prohibits adding new variants to existing enums in any Compatible upgrade. This is not a peripheral restriction. It is a fundamental constraint on the architecture of this protocol.

usufruct encodes all protocol state as sum types:

```move
AssetState::Waiting(WaitingState::Idle { .. })
AssetState::Renting(RentingState::Occupied { .. })
AssetState::Renting(RentingState::Demand { .. })
```

Every new behavior the protocol could express — a new market mode, a new transition, a new policy variant — lives naturally as a new enum variant. That is what sum types are for. Adding a variant is not a workaround; it is the idiomatic extension point of a functional design.

Sui's upgrade rules make that extension point inaccessible after publication. The Compatible upgrade policy — the most permissive available — explicitly prohibits adding new variants to existing enums. See [Upgrading Packages](https://docs.sui.io/develop/publish-upgrade-packages/upgrade) and [Custom Upgrade Policies](https://docs.sui.io/develop/publish-upgrade-packages/custom-policies) in the Sui documentation.

---

## Three Observations, One Decision

### I. Architecture

A functional-style protocol that uses sum types for state representation cannot grow through upgrades. The type system that makes illegal states unrepresentable also makes new states unpublishable after the fact.

This is not a bug in the design. It is the design being honest about what it is. A sum type is a closed enumeration of possibilities. Adding a possibility is a new type, not a modification of the old one. A new version of usufruct with new states is a different protocol — it should have a different identity.

The correct extension model is a new package with its own type hierarchy, its own objects, and its own lifecycle. v1 and v2 coexist on-chain as distinct protocols. Integrators choose which one to work with. Neither invalidates the other.

### II. Ecosystem

This is already how Sui works for developer packages. Every published package receives a unique package ID. When a second version is published, it receives a different ID. The old version remains accessible indefinitely.

Framework packages — Move stdlib at `0x1`, Sui framework at `0x2`, DeepBook at `0xdee9` — are exceptions with special privileges that retain their ID across upgrades. Developer protocols do not have this property and should not design as if they do.

The independent-versions pattern is not an architectural choice we are imposing. It is the behavior Sui provides by default. We are choosing to recognize it consciously and design around it, rather than work against it.

### III. Trust

Sui's documentation is explicit: making a package immutable is the basis for trustless interaction on-chain.

> *"By making packages immutable after publication, users can have confidence that the code they interact with cannot be secretly changed without their knowledge. This makes Sui a trustless blockchain since users don't have to rely on the integrity of third parties."*

Holding an `UpgradeCap` for a package that cannot meaningfully be upgraded adds risk without adding capability. It is a single-key attack surface — a compromised key could publish a malicious upgrade of the implementation even if the type system cannot be extended. It is also a governance risk: any party holding the cap could change function behavior under users without their knowledge.

Burning the cap removes both risks. It is a one-way commitment that the published bytecode is permanent. For a protocol that positions itself as infrastructure — something integrators build on top of — that commitment is not a sacrifice. It is the product.

`sui::package::make_immutable` is a `public entry fun` callable in the same PTB as publish — atomic with deployment, no separate step required:

```bash
sui client ptb \
  --publish ./usufruct \
  --assign cap @UpgradeCap \
  --move-call 0x2::package::make_immutable cap \
  --gas-budget 2000000000
```

> **Verifying immutability.** When `make_immutable` is called, the `UpgradeCap` is permanently deleted from the chain — its UID is destroyed. The proof is the absence of the cap: anyone can verify through Sui Explorer (search the package ID and confirm no `UpgradeCap` is associated), via a GraphQL RPC query filtering `0x2::package::UpgradeCap` objects by package ID, or by inspecting the deploy transaction directly. The guarantee is cryptographic: if the object does not exist on-chain, no upgrade is possible. No trust in any actor is required.

---

## What Versioning Looks Like in Practice

A new version of usufruct is a new Move package. It may share no code with v1 — or it may import v1 as a dependency and build on top of it. Either way, it has its own package ID, its own type definitions, and its own escrow objects.

Objects created under v1 remain under v1 forever. They do not migrate automatically. Users and integrators decide if and when to move to a new version — and they can always stay on v1 if it serves their needs.

This is the correct behavior for a primitive. ERC-20 and ERC-721 do not upgrade. They are what they are. New standards are new standards. The ecosystem coordinates around them, and older standards remain usable indefinitely.

---

## Summary

The three observations — that sum types require independent versioning, that Sui already provides independent package IDs by default, and that immutability is the correct trust signal for a primitive — are not three separate decisions. They are one decision seen from three angles: architecture, ecosystem, and trust.

usufruct is published once per version, immutable, and permanent. New capabilities are new packages.
