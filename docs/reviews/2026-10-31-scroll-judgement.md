# Judgement on the 2026-10-31 scroll review

Japanese translation: `2026-10-31-scroll-judgement.ja.md`. Review: `2026-10-31-scroll-codex.md` (Codex `gpt-6.1-sol`, effort medium, labteam), on commits c20b7b1 and 7c1601f and the §8.2 recovery text.

All four findings are accepted and fixed.

| # | Finding | Decision | Fix |
|---|---|---|---|
| 1 | Recovery by phrase cannot fetch the sealed blob: the relay credential comes from the epoch secret being recovered | Fix | §8.2: the group secret also derives a recovery read credential for that blob only and a recovery signing key whose public key the relay holds; the recovering device reads with the first and registers its device key with the second. Replacing the group secret replaces both |
| 2 | "No phase" also matches trackpad momentum events | Fix | §7 classifies an event as wheel input only when both `phase` and `momentumPhase` are empty; momentum belongs to its gesture and is ignored after `ended` |
| 3 | The pause was inferred from counts in which time and accumulated input grow together | Fix | Measured directly with single events and pairs (section 5): a 40–50 ms sum window above 1.0, a pause of 230–260 ms counted from the switch, not extended by further events. Yab is described only by its counts |
| 4 | 16 events end at about 450 ms, not 330 ms | Fix | Corrected |

Found while fixing 3, not by the review: section 5 claimed a rightward hand motion gives a negative delta on both devices. The owner's "moves right" can mean either the space to the right or the content moving right, so only "the same motion gives the same sign on both devices" is supported; the claim was removed.
