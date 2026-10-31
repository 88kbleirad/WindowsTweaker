# Recommendations

A recommendation is a **proposal**. Building one applies nothing, adds nothing to the pending set
and never discards a selection made by hand.

```text
pwsh -File WindowsTweaker.ps1 -Recommend Privacy -RecommendManual
Get-WtRecommendation -Objective Gaming
Get-WtRecommendationObjective
```

In the terminal interface, `M` opens the view; Left/Right changes the objective and `O` recomputes.
Opening it, changing the objective or recomputing leaves the pending set exactly as it was, and the
view says how many items it kept.

## What a definition may declare

```json
"recommendation": {
  "kind": "Optimization",              // Optimization | Preference | Diagnostic | Repair
  "policy": "Eligible",                // Eligible | Manual | Never
  "objectives": ["Privacy", "Balanced"],
  "rationale": { "en": "...", "vi": "..." },
  "documented": true,                  // the rationale rests on the referenced documentation
  "requiresFinding": "Restart.PendingMarkers"   // repairs only
}
```

This is a *request*, not a right. Missing or unusable metadata excludes an item from automatic
selection, and the reason is reported. `documented` is separate from the evidence status: it is
the author's statement that the rationale rests on the referenced pages, and an item that asks to
be selected automatically without it is offered, never auto-selected
(`Rec.Excluded.Undocumented`).

## What the engine decides

Eligibility is decided by the engine from the definition's own flags, its recovery limits, the
support status that can be vouched for, the verification that can be promised, and the objective the
user asked for:

| Floor | Result |
|---|---|
| No `recommendation` metadata | Excluded (`Rec.Excluded.NoMetadata`) |
| Lifecycle other than `Available` | Excluded |
| `reducesProtection` | **Never** selected automatically |
| `irreversible`, `dataDeletion`, `rollback != Full`, `risk = High` | **Never** selected automatically |
| Support status `AuthorClaimed` or `Unverified` (imported pack) | Manual at best |
| `documented` not true | Manual (offered, never auto-selected) |
| Kind `Diagnostic` | Manual |
| Kind `Preference` | Manual unless preferences are explicitly requested |
| Kind `Repair` without an observed finding | Not offered (`Rec.Excluded.RepairNeedsFinding`) |
| Target without a read-back reader | Unknown (`Rec.Unknown.Verification`) - never recommended |
| Scripted change (targets only known while it runs) | Unknown (`Rec.Unknown.VerificationScript`) |
| `policy: Manual` | Manual |
| `policy: Never` | Never |

An imported pack cannot grant itself anything: whatever its document claims about evidence or risk,
it is offered at most, and `Support` for a pack can only ever be `AuthorClaimed` or `Unverified`.

## Objectives

Each objective is defined independently. When nothing serves it, the answer is "nothing qualifies for
this objective" - the engine does not substitute another one.

| Objective | Definition |
|---|---|
| `Balanced` | Low-risk tidy-ups that change no protection state and restore exactly. Also the only objective that will consider preference items when they are explicitly requested. |
| `Responsiveness` | Reduces background work and diagnostic traffic that competes with the foreground. |
| `Gaming` | Only changes that are not about how the interface looks. **No alternative here claims a frame-rate effect**, and preferences are never taken. |
| `PowerEfficiency` | Reduces background activity, on the understanding that less activity draws less power. |
| `Privacy` | Reduces what Windows collects or sends, without weakening any protection feature. |

Visual and workflow preferences (which folder a window opens to, what the interface shows) are
`Preference` items: manual unless preferences are explicitly requested, and never presented as a
performance improvement.

A **repair** recommendation requires an observed finding from the sanity scan. The finding is
named as `<rule id>` or `<rule id>/<probe id>`, and `Get-WtRecommendation -Finding <rule id>` is
what unlocks it; without the finding the repair is not even offered. The shipped example is
`Mmcss.SystemResponsiveness`, which repairs the finding `Mmcss.TaskOverrides/system-responsiveness`
and is only a candidate while that finding is present. A tweak simply being unapplied is not a
finding.

## The explanation for every item

Nothing is silently dropped. Each considered item carries one decision:

| Decision | Meaning |
|---|---|
| `Recommended` | Serves this objective, every engine floor allows it, and a read-back can be promised after the change. |
| `AlreadySatisfied` | The machine is already in the state the item would set; it is not proposed and will not be rewritten. |
| `Excluded` | Out of automatic consideration, with the reason (no metadata, undocumented, preference, diagnostic, never, protection, recovery, evidence, objective). |
| `Unknown` | Applicability, the current state, or the verification could not be established. |
| `Blocked` | A dependency or a conflict stops it inside this proposal. |

Every item carries its effective-state label together with the evidence class it rests on
(`Observed`/`Inferred`/`Unknown`) and its verification status, so the "why" is never a bare
decision code.

The proposal also carries the dependency plan (`Get-WtDependencyPlan`) for the recommended set, so a
conflict or a cycle inside it demotes the items it involves instead of leaving a plan that cannot be
applied.

## What a proposal is not

* It is not a score, a benchmark or a promise. No item here claims a measured performance gain.
* It is not an action: applying still goes through `Invoke-WtTweak` and its review, journal,
  verification and recovery.
* It is not a decision about the user's own selection: changing the objective never replaces a
  manual choice.
