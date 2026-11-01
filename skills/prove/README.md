# prove — the eval engine skills

The engine (meta) skills that blind-reimplement your shipped units of work and score them adversarially against the human reference — decontaminated. Listed in `core/schema/STRIP_SET.manifest`, so they are stripped from every blind sandbox: `blind-eval` (orchestrator), `sandbox-isolation` (staging + leak-gate), `adversarial-review-loop` (reviewer→red-team→verifier scoring), `skill-improvement-loop` (findings→fix→decontaminated retest).
