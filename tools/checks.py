"""Day 6 checks: a short incident produces a complete postmortem with an ordered timeline."""
import incident
import shop

ev, impact = incident.run(leak_rate=0.3, response_s=5, warmup=15)
md, k = incident.markdown(ev, impact, incident.evidence(ev))
needed = ["start", "first_error", "detected", "mitigated", "recovered"]
missing = [n for n in needed if n not in ev]
print(f"[VERIFY] incident: detected after {k['ttd']:.0f} s, mitigated after {k['ttm']:.0f} s, recovered after {k['ttr']:.0f} s; "
      f"{impact['failed']} of {impact['sent']} checkouts failed")
if missing:
    shop.fail(f"timeline is missing: {missing}")
if not (ev["start"] < ev["first_error"] and ev["detected"] < ev["mitigated"] < ev["recovered"]):
    shop.fail("timeline events are out of order")
for section in ("## Summary", "## Impact", "## Timeline", "## Key numbers", "## Evidence", "## Root cause", "## Action items"):
    if section not in md:
        shop.fail(f"postmortem missing section {section}")
print("[VERIFY] postmortem has summary, impact, timeline, key numbers, evidence, root cause and action items")
