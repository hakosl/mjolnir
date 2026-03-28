# Mjolnir Scoring Rubric

This rubric is shared between the generator (awareness) and evaluator (scoring).

## Criteria

### Design Quality (weight: 0.35, threshold: 7)
The architecture and structure of the code as a coherent system.

- **9-10 Exceptional**: Elegant architecture with perfect separation of concerns. Every module has a clear, single responsibility. Extension points are natural, not forced. The codebase reads like a well-organized library.
- **7-8 Strong**: Good structure with clear boundaries between modules. Minor coupling issues but overall maintainable. Patterns are consistent and appropriate for the problem domain.
- **5-6 Adequate**: Functional but somewhat monolithic. Some god-objects or tight coupling between layers. Could be restructured for clarity.
- **3-4 Weak**: Poor separation of concerns. Business logic mixed with presentation. Difficult to extend or test in isolation.
- **1-2 Absent**: No discernible architecture. Everything in one file or random organization.

### Originality (weight: 0.25, threshold: 5)
Evidence of creative, thoughtful decisions beyond the obvious implementation.

- **9-10 Exceptional**: Surprising, creative solutions that a reviewer would pause to appreciate. Novel data structures, unexpected but elegant API designs, or interaction patterns that feel fresh.
- **7-8 Strong**: Thoughtful approaches with some novel elements. Goes beyond the first obvious solution to find something better. Shows evidence of considering alternatives.
- **5-6 Adequate**: Standard implementation following well-known patterns. Nothing unexpected but nothing wrong. "The tutorial answer."
- **3-4 Weak**: Boilerplate-heavy with no evidence of design thought. Mechanical translation of requirements to code.
- **1-2 Absent**: Copy-paste quality. Feels auto-generated with no human judgment.

### Craft (weight: 0.25, threshold: 6)
Technical execution quality — the polish and consistency of the code itself.

- **9-10 Exceptional**: Beautiful code. Consistent style throughout. Excellent naming that reads like prose. Error handling is thorough but not noisy. Types are precise. Tests are comprehensive and readable.
- **7-8 Strong**: Clean code with good naming conventions. Minor inconsistencies. Error handling covers the important cases. Well-organized imports and dependencies.
- **5-6 Adequate**: Readable but rough edges. Inconsistent patterns across files. Some TODO comments or placeholder error handling. Mixed naming conventions.
- **3-4 Weak**: Messy code with poor naming. Inconsistent indentation or style. Silent error swallowing. Commented-out code left in place.
- **1-2 Absent**: Unreadable. No consistent style. Variables named `x`, `temp`, `data2`.

### Functionality (weight: 0.15, threshold: 6)
Does it work correctly and handle real-world usage?

- **9-10 Exceptional**: Works perfectly for all stated requirements. Edge cases handled gracefully. Error messages are helpful. Performance is appropriate.
- **7-8 Strong**: Core functionality works correctly. Minor edge case issues that don't affect main flows. Reasonable error handling.
- **5-6 Adequate**: Mostly works but has some bugs in secondary flows. Happy path is solid.
- **3-4 Weak**: Partially broken. Some core features don't work or crash under normal usage.
- **1-2 Absent**: Does not run or immediately crashes.

## Scoring Rules

1. Score each criterion independently on a 1-10 integer scale
2. A sprint PASSES only if ALL scores >= their respective thresholds
3. Weighted score = sum(score * weight) across all criteria
4. Provide 2-3 sentence justification for each score
5. If any score is below threshold, provide specific, actionable feedback
6. Be calibrated: a 7 should mean "good, would ship" not "acceptable"
